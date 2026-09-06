local ImportServiceProvider = require("ImportServiceProvider")
local getImmichAlbums = ImportServiceProvider.getImmichAlbums

--------------------------------------------------------------------------------
-- Forward declarations (dialog dispatches to these after close).
local runMobileDeletionsScan, runServerOrphansScan

--------------------------------------------------------------------------------
-- Server -> Lightroom: find catalog photos whose stored Immich asset no longer
-- exists on the server (e.g. culled from a phone). Sequential and cancelable;
-- uses stored-ID existence checks only (deviceAssetId no longer exists).
local function checkAssetExists(immich, assetId)
    local ok, info = LrTasks.pcall(function()
        return immich:doGetRequestAllow404("/assets/" .. assetId)
    end)
    return ok and info ~= nil
end

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

        local allPhotos = catalog:getAllPhotos() or {}
        local candidates = {}
        for _, photo in ipairs(allPhotos) do
            local ok, assetId = LrTasks.pcall(function()
                return photo:getPropertyForPlugin(_PLUGIN, "immichAssetId")
            end)
            if ok and assetId and assetId ~= "" then
                table.insert(candidates, { photo = photo, assetId = assetId })
            end
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
        for i, entry in ipairs(candidates) do
            if progressScope:isCanceled() then
                break
            end
            if i == 1 or i % 10 == 0 or i == #candidates then
                progressScope:setPortionComplete(i, #candidates)
                progressScope:setCaption(string.format("Checking server assets: %d / %d...", i, #candidates))
            end
            if not checkAssetExists(immich, entry.assetId) then
                table.insert(culledPhotos, entry.photo)
            end
        end
        progressScope:done()

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

        progressScope:setCaption("Caching local asset IDs...")
        local localIds = {}
        local allPhotos = catalog:getAllPhotos() or {}
        for i, photo in ipairs(allPhotos) do
            local ok, assetId = LrTasks.pcall(function()
                return photo:getPropertyForPlugin(_PLUGIN, "immichAssetId")
            end)
            if ok and assetId and assetId ~= "" then
                localIds[assetId] = true
            end
            if i % 1000 == 0 then
                progressScope:setPortionComplete(i, #allPhotos)
            end
            if progressScope:isCanceled() then
                break
            end
        end
        if progressScope:isCanceled() then
            progressScope:done()
            return
        end

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
        prefs.syncDeletionsAlbum = prefs.syncDeletionsAlbum or "all"

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
