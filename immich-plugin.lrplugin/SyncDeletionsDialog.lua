local ImportServiceProvider = require("ImportServiceProvider")
local getImmichAlbums = ImportServiceProvider.getImmichAlbums

--------------------------------------------------------------------------------
-- Forward declarations (dialog dispatches to these after close).
local runMobileDeletionsScan, runServerOrphansScan

--------------------------------------------------------------------------------
-- All publish services of this plug-in. Lightroom reports a service's plug-in ID
-- with a two character suffix, hence the substring comparison used in PublishTask.
local function immichPublishServices(catalog)
    if not catalog then
        return {}, nil
    end
    local services = {}
    local ok, err = LrTasks.pcall(function()
        services = catalog:getPublishServices(_PLUGIN.id) or {}
        if #services > 0 then
            return
        end
        services = {}
        for _, service in ipairs(catalog:getPublishServices() or {}) do
            if string.sub(service:getPluginId(), 1, -3) == _PLUGIN.id then
                table.insert(services, service)
            end
        end
    end)
    if not ok then
        log:warn("SyncDeletionsDialog: failed to read publish services: " .. tostring(err))
        return {}, tostring(err)
    end
    return services, nil
end

--------------------------------------------------------------------------------
-- Collect all published collections of a publish service; collections may be
-- nested in collection sets, so recurse.
local function collectPublishedCollections(node, acc)
    for _, collection in ipairs(node:getChildCollections()) do
        table.insert(acc, collection)
    end
    for _, collectionSet in ipairs(node:getChildCollectionSets()) do
        collectPublishedCollections(collectionSet, acc)
    end
end

--------------------------------------------------------------------------------
-- Record an Immich asset ID for a photo in the photo -> IDs map used by both
-- scans. Several collections of one service may record the same asset; de-dupe.
local function addKnownAssetId(byPhoto, photo, assetId)
    if not photo or Util.nilOrEmpty(assetId) then
        return
    end
    assetId = tostring(assetId)
    local entry = byPhoto[photo.localIdentifier]
    if not entry then
        entry = { photo = photo, ids = {} }
        byPhoto[photo.localIdentifier] = entry
    end
    if not Util.table_contains(entry.ids, assetId) then
        table.insert(entry.ids, assetId)
    end
end

--------------------------------------------------------------------------------
-- Every Immich asset ID Lightroom knows for the catalog:
--   * the plugin metadata field immichAssetId (Export, and the last Publish)
--   * Lightroom's published-photo records of every Immich publish service
-- The metadata field holds a single ID per photo and cannot represent the
-- per-service assets Publish now keeps (see PublishTask), so both sources are
-- needed: an asset recorded only by a publish collection is not an orphan.
local function collectKnownAssetIds(catalog, progressScope)
    local byPhoto = {}
    local firstError = nil
    local allPhotos = catalog:getAllPhotos() or {}
    for i, photo in ipairs(allPhotos) do
        local ok, assetId = LrTasks.pcall(function()
            return photo:getPropertyForPlugin(_PLUGIN, "immichAssetId")
        end)
        if ok then
            addKnownAssetId(byPhoto, photo, assetId)
        else
            firstError = firstError or ("photo metadata: " .. tostring(assetId))
        end
        if progressScope and (i % 1000 == 0 or i == #allPhotos) then
            progressScope:setCaption(string.format("Caching local asset IDs: %d / %d...", i, #allPhotos))
        end
        if progressScope and progressScope:isCanceled() then
            break
        end
    end

    if progressScope and progressScope:isCanceled() then
        return byPhoto, nil
    end

    local services, servicesError = immichPublishServices(catalog)
    if servicesError then
        return byPhoto, "publish services: " .. servicesError
    end

    for _, service in ipairs(services) do
        local collections = {}
        local okCollections, err = LrTasks.pcall(function()
            collectPublishedCollections(service, collections)
        end)
        if not okCollections then
            firstError = firstError or ("published collections: " .. tostring(err))
        else
            for _, collection in ipairs(collections) do
                local okPhotos, publishedPhotos = LrTasks.pcall(function()
                    return collection:getPublishedPhotos()
                end)
                if not okPhotos then
                    firstError = firstError or ("published photos: " .. tostring(publishedPhotos))
                elseif publishedPhotos then
                    for _, publishedPhoto in ipairs(publishedPhotos) do
                        local okRemote, remoteId = LrTasks.pcall(function()
                            return publishedPhoto:getRemoteId()
                        end)
                        local okPhoto, photo = LrTasks.pcall(function()
                            return publishedPhoto:getPhoto()
                        end)
                        if okRemote and okPhoto then
                            addKnownAssetId(byPhoto, photo, remoteId)
                        else
                            firstError = firstError or "published photo record"
                        end
                    end
                end
            end
        end
        if progressScope and progressScope:isCanceled() then
            break
        end
    end

    return byPhoto, firstError
end

--------------------------------------------------------------------------------
-- Flatten the photo -> IDs map into a set of asset IDs.
local function knownAssetIdSet(byPhoto)
    local ids = {}
    for _, entry in pairs(byPhoto) do
        for _, assetId in ipairs(entry.ids) do
            ids[assetId] = true
        end
    end
    return ids
end

--------------------------------------------------------------------------------
-- Classify an asset without the connectivity round-trip of
-- doGetRequestAllow404, which is far too expensive for a per-asset scan.
-- Returns "alive", "gone" (missing or trashed), or nil when the request itself
-- failed and the asset state is unknown.
local function checkAssetPresence(immich, assetId)
    local ok, status, err = LrTasks.pcall(function()
        return immich:getAssetPresence(assetId)
    end)
    if not ok then
        return nil, tostring(status)
    end
    return status, err
end

--------------------------------------------------------------------------------
-- Server -> Lightroom: find catalog photos whose stored Immich asset no longer
-- exists on the server (e.g. culled from a phone). Sequential and cancelable.

runMobileDeletionsScan = function()
    LrTasks.startAsyncTask(function()
        local catalog = LrApplication.activeCatalog()
        if not catalog then
            LrDialogs.message("Error", "Could not open active catalog.", "critical")
            return
        end

        local progressScope = LrProgressScope({
            title = "Scanning Immich for Mobile Deletions",
            caption = "Connecting...",
        })

        local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        if not immich:checkConnectivity() then
            progressScope:done()
            LrDialogs.message("Error", "Could not connect to Immich server. Please check your URL/key.", "critical")
            return
        end

        progressScope:setCaption("Caching known asset IDs...")
        local byPhoto, collectError = collectKnownAssetIds(catalog, progressScope)
        if collectError then
            progressScope:done()
            LrDialogs.message(
                "Scan Aborted",
                "Could not read Lightroom's Immich asset references: "
                    .. collectError
                    .. "\n\nNothing was added to the culled collection. Try again once the catalog is idle.",
                "critical"
            )
            return
        end
        if progressScope:isCanceled() then
            progressScope:done()
            return
        end

        local candidates = {}
        for _, entry in pairs(byPhoto) do
            table.insert(candidates, entry)
        end

        if #candidates == 0 then
            progressScope:done()
            LrDialogs.message(
                "Scan Complete",
                "No uploaded Immich assets found in your Lightroom catalog to scan.",
                "info"
            )
            return
        end

        local culledPhotos = {}
        local unknownError = nil
        for i, entry in ipairs(candidates) do
            if progressScope:isCanceled() then
                break
            end
            if i == 1 or i % 10 == 0 or i == #candidates then
                progressScope:setPortionComplete(i, #candidates)
                progressScope:setCaption(string.format("Checking server assets: %d / %d...", i, #candidates))
            end

            -- A photo may hold several assets (one per publish service). It is
            -- culled only when every asset Lightroom knows for it is gone.
            local alive = false
            for _, assetId in ipairs(entry.ids) do
                local status, err = checkAssetPresence(immich, assetId)
                if status == "alive" then
                    alive = true
                    break
                elseif status == nil then
                    unknownError =
                        string.format("%s (%s)", entry.photo:getFormattedMetadata("fileName") or "photo", tostring(err))
                    break
                end
            end
            if unknownError then
                break
            end
            if not alive then
                table.insert(culledPhotos, entry.photo)
            end
        end
        progressScope:done()

        if unknownError then
            LrDialogs.message(
                "Scan Aborted",
                "Could not determine whether a photo still exists on Immich: "
                    .. unknownError
                    .. "\n\nNothing was added to the culled collection. Check the server connection and try again.",
                "critical"
            )
            return
        end

        if progressScope:isCanceled() then
            LrDialogs.message("Scan Cancelled", "The deletion sync scan was cancelled.", "info")
            return
        end

        if #culledPhotos == 0 then
            LrDialogs.message(
                "Scan Complete",
                "All checked photos still exist on the Immich server. No mobile-deleted photos found!",
                "info"
            )
            return
        end

        local choice = LrDialogs.confirm(
            string.format("Found %d Culled Photos", #culledPhotos),
            string.format(
                "Found %d photos that were deleted from Immich (e.g. from your mobile phone).\n\n"
                    .. "Put them into 'Immich Mobile Deleted / Culled' for review?",
                #culledPhotos
            ),
            "Add to Collection",
            "Cancel"
        )
        if choice == "ok" then
            catalog:withWriteAccessDo("Create Immich Culled Collection", function()
                local collection = catalog:createCollection("Immich Mobile Deleted / Culled", nil, true)
                if collection then
                    local existing = collection:getPhotos()
                    if #existing > 0 then
                        collection:removePhotos(existing)
                    end
                    collection:addPhotos(culledPhotos)
                end
            end)
            LrDialogs.message(
                "Success",
                string.format(
                    "Added %d photos to collection 'Immich Mobile Deleted / Culled'.\n\n"
                        .. "Select it in the left panel to review them.",
                    #culledPhotos
                ),
                "info"
            )
        end
    end)
end

--------------------------------------------------------------------------------
-- Lightroom -> Server: find remote album assets whose ID is not stored on any
-- catalog photo (local photo deleted from Lightroom). User confirms before
-- anything is trashed. Note: assets uploaded outside Lightroom (e.g. phone
-- camera uploads in the same albums) also appear here by design.
runServerOrphansScan = function(syncDeletionsAlbum)
    LrTasks.startAsyncTask(function()
        local catalog = LrApplication.activeCatalog()
        if not catalog then
            LrDialogs.message("Error", "Could not open active catalog.", "critical")
            return
        end

        local progressScope = LrProgressScope({
            title = "Scanning for Server Orphans",
            caption = "Connecting...",
        })

        local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        if not immich:checkConnectivity() then
            progressScope:done()
            LrDialogs.message("Error", "Could not connect to Immich server. Please check your URL/key.", "critical")
            return
        end

        progressScope:setCaption("Caching known asset IDs...")
        local byPhoto, collectError = collectKnownAssetIds(catalog, progressScope)
        if collectError then
            progressScope:done()
            LrDialogs.message(
                "Scan Aborted",
                "Could not read Lightroom's Immich asset references: "
                    .. collectError
                    .. "\n\nNothing was deleted. Try again once the catalog is idle.",
                "critical"
            )
            return
        end
        if progressScope:isCanceled() then
            progressScope:done()
            return
        end
        local localIds = knownAssetIdSet(byPhoto)

        progressScope:setCaption("Fetching remote assets...")
        local targetAlbums = {}
        if not syncDeletionsAlbum or syncDeletionsAlbum == "all" then
            for _, album in ipairs(immich:getAlbumsWODate() or {}) do
                table.insert(targetAlbums, album)
            end
        else
            table.insert(targetAlbums, { value = syncDeletionsAlbum, title = "Selected Album" })
        end
        if #targetAlbums == 0 then
            progressScope:done()
            LrDialogs.message("Error", "No albums found to scan.", "critical")
            return
        end

        local orphans = {}
        local seen = {}
        local totalAssets = 0
        for _, album in ipairs(targetAlbums) do
            if progressScope:isCanceled() then
                break
            end
            progressScope:setCaption("Fetching: " .. tostring(album.title or album.value))
            local assets = immich:getAlbumAssets(album.value) or {}
            for _, asset in ipairs(assets) do
                totalAssets = totalAssets + 1
                if asset and asset.id and not seen[asset.id] then
                    seen[asset.id] = true
                    if not localIds[asset.id] then
                        table.insert(orphans, asset)
                    end
                end
            end
        end
        progressScope:done()

        if progressScope:isCanceled() then
            LrDialogs.message("Scan Cancelled", "The deletion sync scan was cancelled.", "info")
            return
        end

        if #orphans == 0 then
            LrDialogs.message(
                "Scan Complete",
                "No server orphans found! Every remote asset (" .. totalAssets .. " checked) is still in your catalog.",
                "info"
            )
            return
        end

        local choice = LrDialogs.confirm(
            string.format("Found %d Server Orphans", #orphans),
            string.format(
                "Found %d assets on Immich not referenced by any photo in your Lightroom catalog.\n\n"
                    .. "This includes photos you deleted from Lightroom, but also photos uploaded outside Lightroom "
                    .. "(e.g. phone camera uploads in the same albums).\n\nDelete these orphaned assets from Immich?",
                #orphans
            ),
            "Delete from Server",
            "Cancel"
        )
        if choice == "ok" then
            local deleteScope = LrProgressScope({ title = "Deleting Orphans from Immich" })
            local deletedCount = 0
            for i, asset in ipairs(orphans) do
                if deleteScope:isCanceled() then
                    break
                end
                if immich:deleteAsset(asset.id) then
                    deletedCount = deletedCount + 1
                end
                deleteScope:setPortionComplete(i, #orphans)
                deleteScope:setCaption(string.format("Deleted %d of %d", deletedCount, #orphans))
            end
            deleteScope:done()
            LrDialogs.message(
                "Done",
                string.format("Deleted %d of %d orphaned assets from Immich.", deletedCount, #orphans),
                "info"
            )
        end
    end)
end

--------------------------------------------------------------------------------
return {
    LrTasks.startAsyncTask(function()
        if not prefs.url or not prefs.apiKey or prefs.url == "" or prefs.apiKey == "" then
            LrDialogs.message(
                "Configuration Required",
                "Please configure the Immich URL and API key in Plug-in Extras -> Immich import configuration first.",
                "info"
            )
            return
        end

        local albums = getImmichAlbums() or {}
        table.insert(albums, 1, { title = "Scan All Albums", value = "all" })
        -- Default to a single album: "all" also covers albums this plug-in never
        -- uploaded to (e.g. phone camera uploads) and is easy to confirm by mistake.
        -- Keep a previously chosen album while it still exists.
        local savedAlbumExists = false
        for _, album in ipairs(albums) do
            if album.value == prefs.syncDeletionsAlbum then
                savedAlbumExists = true
                break
            end
        end
        if not savedAlbumExists then
            prefs.syncDeletionsAlbum = (#albums > 1) and albums[2].value or "all"
        end

        local f = LrView.osFactory()
        local pendingScan = nil -- "mobile", "orphans", or nil

        local contents = f:column({
            bind_to_object = prefs,
            spacing = f:control_spacing(),
            margin = 15,
            f:group_box({
                title = "1. Mobile Culling Sync (Server to Lightroom)",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    margin = 8,
                    f:static_text({
                        title = "Finds catalog photos deleted directly on Immich (e.g. culled from your phone). "
                            .. "Matches are placed in 'Immich Mobile Deleted / Culled' for review.",
                        alignment = "left",
                        font = "<system/small>",
                        fill_horizontal = 1,
                    }),
                    f:row({
                        margin_top = 10,
                        f:push_button({
                            title = "Scan for Mobile Deletions",
                            action = function()
                                pendingScan = "mobile"
                                LrDialogs.closeCurrentModal("ok")
                            end,
                        }),
                    }),
                }),
            }),
            f:group_box({
                title = "2. Clean Server Orphans (Lightroom to Server)",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    margin = 8,
                    f:static_text({
                        title = "Finds Immich assets not referenced by your catalog. Review before deleting: "
                            .. "phone uploads in the same albums also appear here.",
                        alignment = "left",
                        font = "<system/small>",
                        fill_horizontal = 1,
                    }),
                    f:row({
                        margin_top = 10,
                        f:static_text({
                            title = "Album to audit:",
                            alignment = "right",
                            width = LrView.share("label_width"),
                        }),
                        f:popup_menu({
                            items = albums,
                            value = LrView.bind("syncDeletionsAlbum"),
                            width = 200,
                        }),
                        f:push_button({
                            title = "Scan for Server Orphans",
                            action = function()
                                pendingScan = "orphans"
                                LrDialogs.closeCurrentModal("ok")
                            end,
                        }),
                    }),
                }),
            }),
        })

        LrDialogs.presentModalDialog({
            title = "Sync & Clean Deletions",
            contents = contents,
            actionVerb = "Close",
        })

        if pendingScan == "mobile" then
            local ok, err = LrTasks.pcall(runMobileDeletionsScan)
            if not ok then
                log:error("Mobile deletion scan error: " .. tostring(err))
            end
        elseif pendingScan == "orphans" then
            local ok, err = LrTasks.pcall(function()
                runServerOrphansScan(prefs.syncDeletionsAlbum)
            end)
            if not ok then
                log:error("Server orphans scan error: " .. tostring(err))
            end
        end
    end),
}
