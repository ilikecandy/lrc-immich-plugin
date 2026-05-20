local ImportServiceProvider = require("ImportServiceProvider")
local getImmichAlbums = ImportServiceProvider.getImmichAlbums

local function runMobileDeletionsScan()
    LrTasks.startAsyncTask(function()
        local catalog = LrApplication.activeCatalog()
        if not catalog then
            LrDialogs.message("Error", "Could not open active catalog.", "critical")
            return
        end

        local allPhotos = catalog:getAllPhotos()
        
        -- Phase 1: Filter photos with an Immich Asset ID
        local matchedPhotos = {}
        for _, photo in ipairs(allPhotos) do
            local assetId = photo:getPropertyForPlugin(_PLUGIN, "immichAssetId")
            if assetId and assetId ~= "" then
                table.insert(matchedPhotos, photo)
            end
        end

        if #matchedPhotos == 0 then
            LrDialogs.message("Scan Complete", "No uploaded Immich assets found in your Lightroom catalog to scan.", "info")
            return
        end

        local progressScope = LrProgressScope({
            title = "Scanning Immich for Mobile Deletions",
            caption = "Initializing connection...",
        })

        local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        if not immich:checkConnectivity() then
            progressScope:done()
            LrDialogs.message("Error", "Could not connect to Immich server. Please check your URL/key.", "critical")
            return
        end

        -- Phase 2: Bulk check deviceAssetIds in batches of 500
        progressScope:setCaption("Performing bulk server check...")
        local existingDeviceAssetIds = {}
        for i = 1, #matchedPhotos, 500 do
            if progressScope:isCanceled() then break end
            
            local batchIds = {}
            for j = i, math.min(i + 499, #matchedPhotos) do
                local photo = matchedPhotos[j]
                local devId = util.getPhotoDeviceId(photo)
                if devId then
                    table.insert(batchIds, devId .. "_export")
                    table.insert(batchIds, devId)
                end
            end
            
            local existingMap = immich:bulkCheckAssets(batchIds)
            for k, _ in pairs(existingMap) do
                existingDeviceAssetIds[k] = true
            end
            progressScope:setPortionComplete(i, #matchedPhotos)
        end

        -- Phase 3: Double-check missing items individually (avoid false positives due to network glitches or mismatches)
        progressScope:setCaption("Double-checking potential deletions...")
        local culledPhotos = {}
        local checkedCount = 0
        
        for idx, photo in ipairs(matchedPhotos) do
            if progressScope:isCanceled() then break end
            
            local devId = util.getPhotoDeviceId(photo)
            local existsInBulk = false
            if devId then
                if existingDeviceAssetIds[devId] or existingDeviceAssetIds[devId .. "_export"] then
                    existsInBulk = true
                end
            end
            
            if not existsInBulk then
                -- Double check by direct API query
                local assetId = photo:getPropertyForPlugin(_PLUGIN, "immichAssetId")
                if assetId and assetId ~= "" then
                    local info = immich:doGetRequestAllow404("/assets/" .. assetId)
                    if not info then
                        table.insert(culledPhotos, photo)
                    end
                end
            end
            
            checkedCount = checkedCount + 1
            progressScope:setPortionComplete(checkedCount, #matchedPhotos)
            progressScope:setCaption(string.format("Checking: %d of %d (Found %d mobile-deleted)", checkedCount, #matchedPhotos, #culledPhotos))
        end

        progressScope:done()

        if progressScope:isCanceled() then
            LrDialogs.message("Scan Cancelled", "The deletion sync scan was cancelled.", "info")
            return
        end

        if #culledPhotos == 0 then
            LrDialogs.message("Scan Complete", "All checked photos still exist on the Immich server. No mobile-deleted photos found!", "info")
            return
        end

        -- Phase 4: Create target collection and add the culled photos
        local choice = LrDialogs.confirm(
            string.format("Found %d Culled Photos", #culledPhotos),
            string.format("Found %d photos that were deleted from Immich (e.g. from your mobile phone).\n\nWould you like to put them into a Lightroom collection named 'Immich Mobile Deleted / Culled' so you can review and delete them from your PC?", #culledPhotos),
            "Add to Collection", "Cancel"
        )
        
        if choice == "ok" then
            catalog:withWriteAccessDo("Create Immich Culled Collection", function()
                local collection = catalog:createCollection("Immich Mobile Deleted / Culled", nil, true)
                if collection then
                    -- Clear existing photos in the collection first to keep it fresh
                    local existing = collection:getPhotos()
                    if #existing > 0 then
                        collection:removePhotos(existing)
                    end
                    collection:addPhotos(culledPhotos)
                end
            end)
            LrDialogs.message("Success", string.format("Added %d photos to collection 'Immich Mobile Deleted / Culled'.\n\nYou can now select this collection in the left panel to review and delete them from your catalog.", #culledPhotos), "info")
        end
    end)
end

local function runServerOrphansScan(syncDeletionsAlbum)
    LrTasks.startAsyncTask(function()
        local catalog = LrApplication.activeCatalog()
        if not catalog then
            LrDialogs.message("Error", "Could not open active catalog.", "critical")
            return
        end

        local progressScope = LrProgressScope({
            title = "Scanning for Server Orphans",
            caption = "Initializing...",
        })

        local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        if not immich:checkConnectivity() then
            progressScope:done()
            LrDialogs.message("Error", "Could not connect to Immich server. Please check your URL/key.", "critical")
            return
        end

        -- Step 1: Map all local catalog photos by their unique Device ID / UUID for instant O(1) checks
        progressScope:setCaption("Caching local catalog identifiers...")
        local localPhotoLookup = {}
        local allPhotos = catalog:getAllPhotos()
        for i, p in ipairs(allPhotos) do
            local devId = util.getPhotoDeviceId(p)
            if devId then
                localPhotoLookup[devId] = p
            end
            if i % 1000 == 0 then
                progressScope:setPortionComplete(i, #allPhotos)
            end
        end

        -- Step 2: Fetch target album assets
        progressScope:setCaption("Fetching remote assets...")
        local targetAlbums = {}
        if syncDeletionsAlbum == "all" then
            local albums = immich:getAlbumsWODate()
            if albums then
                for _, album in ipairs(albums) do
                    table.insert(targetAlbums, album)
                end
            end
        else
            table.insert(targetAlbums, { value = syncDeletionsAlbum, title = "Selected Album" })
        end

        if #targetAlbums == 0 then
            progressScope:done()
            LrDialogs.message("Error", "No albums found to scan.", "critical")
            return
        end

        local remoteAssets = {}
        for idx, album in ipairs(targetAlbums) do
            if progressScope:isCanceled() then break end
            progressScope:setCaption("Fetching remote assets from: " .. album.title)
            local assets = immich:getAlbumAssets(album.value)
            if assets then
                for _, asset in ipairs(assets) do
                    table.insert(remoteAssets, asset)
                end
            end
            progressScope:setPortionComplete(idx, #targetAlbums)
        end

        if #remoteAssets == 0 then
            progressScope:done()
            LrDialogs.message("Scan Complete", "No remote assets found in the scanned albums.", "info")
            return
        end

        -- Step 3: Match remote assets back to local catalog
        progressScope:setCaption("Analyzing database for catalog deletions...")
        local orphans = {}
        local uniqueOrphans = {}
        for idx, asset in ipairs(remoteAssets) do
            if progressScope:isCanceled() then break end
            
            local devId = asset.deviceAssetId
            if devId and devId ~= "" then
                -- Strip suffixes to extract original photo UUID
                local baseId = string.gsub(devId, "_export$", "")
                baseId = string.gsub(baseId, "_orig$", "")
                baseId = string.gsub(baseId, "_rend%d+$", "")
                baseId = string.gsub(baseId, "_original$", "")
                
                if #baseId >= 8 then
                    if not localPhotoLookup[baseId] then
                        if not uniqueOrphans[asset.id] then
                            uniqueOrphans[asset.id] = true
                            table.insert(orphans, asset)
                        end
                    end
                end
            end
            progressScope:setPortionComplete(idx, #remoteAssets)
        end

        progressScope:done()

        if progressScope:isCanceled() then
            LrDialogs.message("Scan Cancelled", "The deletion sync scan was cancelled.", "info")
            return
        end

        if #orphans == 0 then
            LrDialogs.message("Scan Complete", "No server orphans found! Every remote asset still exists in your Lightroom catalog.", "info")
            return
        end

        -- Step 4: Confirm and delete orphaned assets from Immich
        local choice = LrDialogs.confirm(
            string.format("Found %d Server Orphans", #orphans),
            string.format("Found %d assets on Immich whose local photos were completely deleted from Lightroom.\n\nWould you like to delete/trash these orphaned assets from the Immich server?", #orphans),
            "Delete from Server (Danger)", "Cancel"
        )

        if choice == "ok" then
            local deleteProgress = LrProgressScope({
                title = "Deleting Orphans from Immich",
                caption = "Starting deletion...",
            })
            
            local deletedCount = 0
            for idx, asset in ipairs(orphans) do
                if deleteProgress:isCanceled() then break end
                
                local ok = immich:deleteAsset(asset.id)
                if ok then
                    deletedCount = deletedCount + 1
                end
                
                deleteProgress:setPortionComplete(idx, #orphans)
                deleteProgress:setCaption(string.format("Deleted %d of %d assets from server", deletedCount, #orphans))
            end
            
            deleteProgress:done()
            LrDialogs.message("Success", string.format("Successfully deleted %d of %d orphaned assets from the Immich server.", deletedCount, #orphans), "info")
        end
    end)
end

return {
    LrTasks.startAsyncTask(function()
        -- Ensure configuration is loaded
        if not prefs.url or not prefs.apiKey or prefs.url == "" or prefs.apiKey == "" then
            LrDialogs.message("Configuration Required", "Please configure the Immich URL and API key in Plug-in Extras -> Immich import configuration first.", "info")
            return
        end

        local albums = getImmichAlbums()
        if not albums then
            albums = {}
        end
        table.insert(albums, 1, { title = "Scan All Albums", value = "all" })

        -- Default selection
        prefs.syncDeletionsAlbum = prefs.syncDeletionsAlbum or "all"

        -- Dialog UI
        local f = LrView.osFactory()
        local contents = f:column({
            bind_to_object = prefs,
            spacing = f:control_spacing(),
            margin = 15,

            f:group_box({
                title = "1. Mobile Culling Sync (Server ➔ Lightroom)",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    margin = 8,
                    f:static_text({
                        title = "Finds photos in your Lightroom catalog that have been deleted/trashed directly on Immich (e.g., culled from your phone in bed). Found photos will be placed in a Lightroom collection named 'Immich Mobile Deleted / Culled' so you can review and delete them locally.",
                        alignment = "left",
                        font = "<system/small>",
                        width_in_chars = 60,
                        fill_horizontal = 1,
                    }),
                    f:row({
                        margin_top = 10,
                        f:push_button({
                            title = "Scan for Mobile Deletions",
                            action = function(button)
                                -- Dismiss the setup dialog to run the scan task
                                LrDialogs.closeCurrentModal("scan_mobile")
                            end,
                        }),
                    }),
                }),
            }),

            f:group_box({
                title = "2. Clean Server Orphans (Lightroom ➔ Server)",
                fill_horizontal = 1,
                f:column({
                    spacing = f:control_spacing(),
                    margin = 8,
                    f:static_text({
                        title = "Finds photos on Immich that were completely deleted from your local Lightroom catalog. You can review the list of these orphaned assets and choose to delete them from the Immich server in one click.",
                        alignment = "left",
                        font = "<system/small>",
                        width_in_chars = 60,
                        fill_horizontal = 1,
                    }),
                    f:row({
                        margin_top = 10,
                        f:static_text({
                            title = "Immich Album to Audit:",
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
                            action = function(button)
                                LrDialogs.closeCurrentModal("scan_orphans")
                            end,
                        }),
                    }),
                }),
            }),
        })

        -- Show setup dialog
        local result = LrDialogs.presentModalDialog({
            title = "Sync & Clean Deletions",
            contents = contents,
            actionVerb = "Close",
            cancelVerb = "", -- Hide cancel button to make Close the only option
        })

        if result == "scan_mobile" then
            runMobileDeletionsScan()
        elseif result == "scan_orphans" then
            runServerOrphansScan(prefs.syncDeletionsAlbum)
        end
    end)
}
