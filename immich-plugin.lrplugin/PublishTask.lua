require("ImmichAPI")
require("StackManager")
require("UploadHelpers")
require("MetadataTask")

PublishTask = {}

--------------------------------------------------------------------------------
-- Resolves the locked folder visibility string from lockedFolderMode setting.
-- Returns "private" to upload to locked folder, nil for normal upload.
local function resolveLockedFolder(exportParams)
    local mode = exportParams.lockedFolderMode
    if not mode or mode == "none" then
        return nil
    elseif mode == "always" then
        return "locked"
    elseif mode == "ask" then
        local result = LrDialogs.confirm(
            "Upload to Locked Folder?",
            "Photos will be hidden from the timeline and require a PIN to view in Immich.",
            "Yes",
            "No"
        )
        return (result == "ok") and "locked" or nil
    end
    return nil
end

--------------------------------------------------------------------------------
-- Resolve or create album for publish; record remote id/url on exportSession.
-- Returns: albumCreationStrategy, albumId, albumAssetIds.
local function resolvePublishAlbum(immich, exportContext)
    local publishedCollection = exportContext.publishedCollection
    local collectionSettings = publishedCollection:getCollectionInfoSummary().collectionSettings
    local albumCreationStrategy = collectionSettings.albumCreationStrategy or "collection"
    local albumId = publishedCollection and publishedCollection:getRemoteId()
    local albumName = publishedCollection and publishedCollection:getName()
    local albumAssetIds = nil
    local exportSession = exportContext.exportSession

    log:trace("Album creation strategy used: " .. albumCreationStrategy)

    if albumCreationStrategy == "collection" or albumCreationStrategy == "existing" then
        if albumId and immich:checkIfAlbumExists(albumId) then
            albumAssetIds = immich:getAlbumAssetIds(albumId)
            exportSession:recordRemoteCollectionId(albumId)
            exportSession:recordRemoteCollectionUrl(immich:getAlbumUrl(albumId))
        else
            albumId = immich:createAlbum(albumName)
            albumAssetIds = {}
            exportSession:recordRemoteCollectionId(albumId)
            exportSession:recordRemoteCollectionUrl(immich:getAlbumUrl(albumId))
        end
    end
    return albumCreationStrategy, albumId, albumAssetIds
end

--------------------------------------------------------------------------------
-- Add asset to album (publish logic: folder vs collection/existing).
local function addAssetToPublishAlbum(immich, albumCreationStrategy, albumId, albumAssetIds, assetId, folderName)
    if albumCreationStrategy == "folder" then
        local folderAlbumId = immich:createOrGetAlbumFolderBased(folderName)
        if folderAlbumId then
            immich:addAssetToAlbum(folderAlbumId, assetId)
        end
    elseif albumId and (not albumAssetIds or not util.table_contains(albumAssetIds, assetId)) then
        immich:addAssetToAlbum(albumId, assetId)
    end
end

--------------------------------------------------------------------------------
-- Process one photo group in original+export publish flow.
-- Mutates failures, stackWarnings, atLeastSomeSuccess, exportedPrimaryByPhoto.
local function processPublishOnePhotoGroup(
    immich,
    lid,
    items,
    albumCreationStrategy,
    albumId,
    albumAssetIds,
    failures,
    stackWarnings,
    atLeastSomeSuccess,
    exportedPrimaryByPhoto,
    visibility
)
    if not items or not items[1] then
        return
    end
    local photo = items[1].photo
    local filename = photo:getFormattedMetadata("fileName")
    local dateCreated = photo:getFormattedMetadata("dateCreated")
    if #items >= 2 then
        UploadHelpers.sortOriginalExportItems(items)
        local assetIds = {}
        local primaryId = nil
        for i, item in ipairs(items) do
            -- After sort: items[1]=export (primary), items[2]=original.
            -- Suffix is stable for the expected two-item pair; extra renditions get an index suffix.
            local suffix = (i == 1) and "_export" or (i == 2) and "_orig" or ("_rend" .. tostring(i))
            local deviceAssetId = lid .. suffix
            local id, errReason = StackManager.uploadOneAssetOrReplace(
                immich,
                item.path,
                deviceAssetId,
                filename,
                dateCreated,
                visibility
            )
            UploadHelpers.safeDeleteTempFile(item.path)
            if not id then
                table.insert(failures, filename .. " (" .. (errReason or "Upload failed") .. ")")
            else
                atLeastSomeSuccess[1] = true
                table.insert(assetIds, id)
                if primaryId == nil then
                    primaryId = id
                end
                item.rendition:recordPublishedPhotoId(id)
                item.rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))
                log:info("original+export [" .. filename .. "]: " .. deviceAssetId .. " -> " .. id)
            end
        end
        if #assetIds >= 2 and primaryId then
            if not immich:createStack(assetIds) then
                table.insert(stackWarnings, filename .. ": Failed to create original+export stack")
            end
        end
        if primaryId then
            MetadataTask.setImmichAssetId(photo, primaryId)
            exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
            addAssetToPublishAlbum(
                immich,
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                primaryId,
                photo:getFormattedMetadata("folderName")
            )
        end
    elseif #items == 1 then
        -- One rendition arrived. Since LR_exportOriginalFile is never set, Lightroom always
        -- delivers the rendered export (never an original-copy rendition), so item.role = "export".
        -- Always treat the single rendition as the export.
        -- Do NOT upload the disk original: assets uploaded outside of recordPublishedPhotoId
        -- cannot be tracked by Lightroom and become orphans when the photo is removed from the
        -- publish collection (deletePhotosFromPublishedCollection only cleans up assets
        -- registered via recordPublishedPhotoId). Warn instead.
        local item = items[1]
        local deviceAssetId = lid .. "_export"
        log:info(
            "original+export [" .. filename .. "]: single rendition, uploading as export (" .. deviceAssetId .. ")"
        )
        local id, errReason =
            StackManager.uploadOneAssetOrReplace(immich, item.path, deviceAssetId, filename, dateCreated, visibility)
        UploadHelpers.safeDeleteTempFile(item.path)
        if not id then
            table.insert(failures, filename .. " (" .. (errReason or "Upload failed") .. ")")
        else
            atLeastSomeSuccess[1] = true
            local primaryId = id
            MetadataTask.setImmichAssetId(photo, primaryId)
            item.rendition:recordPublishedPhotoId(id)
            item.rendition:recordPublishedPhotoUrl(immich:getAssetUrl(id))
            -- Warn once per publish run (not once per photo) to keep the post-publish dialog concise.
            if not stackWarnings._originalNotUploadedWarned then
                table.insert(
                    stackWarnings,
                    "Originals not uploaded in publish mode to avoid untracked orphans in Immich"
                        .. " (applies to all photos in this run)"
                )
                stackWarnings._originalNotUploadedWarned = true
            end
            exportedPrimaryByPhoto[photo.localIdentifier] = { assetId = primaryId, photo = photo }
            addAssetToPublishAlbum(
                immich,
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                primaryId,
                photo:getFormattedMetadata("folderName")
            )
        end
    end
end

--------------------------------------------------------------------------------
-- Original+export flow: process each rendition immediately as it arrives, keeping
-- renders and uploads interleaved so the Lightroom progress bar advances
-- proportionally to real work done. LR_exportOriginalFile is never set, so LR
-- always delivers exactly one rendition per photo; the disk original is fetched
-- inside processPublishOnePhotoGroup (or skipped for orphan safety in publish mode).
local function processPublishStackOriginalExportRenditions(
    immich,
    renditionsList,
    progressScope,
    nPhotos,
    albumCreationStrategy,
    albumId,
    albumAssetIds,
    visibility,
    state
)
    for _, rendition in ipairs(renditionsList) do
        if progressScope:isCanceled() then
            break
        end
        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then
            break
        end
        if success then
            -- Use stable device ID (UUID when available) so deviceAssetIds survive catalog re-imports.
            local lid = util.getPhotoDeviceId(rendition.photo) or rendition.photo.localIdentifier
            -- role = "export": LR_exportOriginalFile is never set, so LR always delivers the
            -- rendered export (never an original-copy rendition), regardless of file extension.
            local item = {
                path = pathOrMessage,
                photo = rendition.photo,
                rendition = rendition,
                role = "export",
            }
            local successWrapper = { state.atLeastSomeSuccess }
            processPublishOnePhotoGroup(
                immich,
                lid,
                { item },
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                state.failures,
                state.stackWarnings,
                successWrapper,
                state.exportedPrimaryByPhoto,
                visibility
            )
            if successWrapper[1] then
                state.atLeastSomeSuccess = true
            end
        end
        -- Advance progress for every rendition, including failed renders, so the bar reaches 100%.
        state.done = state.done + 1
        progressScope:setPortionComplete(state.done, nPhotos)
        if state.done == 1 or state.done % 10 == 0 or state.done == nPhotos then
            log:info("Publish progress: " .. state.done .. "/" .. nPhotos .. " (" .. math.floor(state.done * 100 / nPhotos) .. "%)")
        end
    end
end

--------------------------------------------------------------------------------
local function processPublishSingleRenditionRenditions(
    immich,
    renditionsList,
    progressScope,
    nPhotos,
    exportParams,
    albumCreationStrategy,
    albumId,
    albumAssetIds,
    visibility,
    state
)
    -- Build O(1) cache of existing album assets in a single network request to eliminate sequential check latency!
    local albumAssetsCache = nil
    if albumId and albumId ~= "" then
        log:info("processPublishSingleRenditionRenditions: Pre-fetching album assets for cache...")
        local assets = immich:getAlbumAssets(albumId)
        if assets then
            albumAssetsCache = {
                ids = {},
                deviceIds = {}
            }
            for _, asset in ipairs(assets) do
                if asset.id then
                    albumAssetsCache.ids[asset.id] = true
                end
                if asset.deviceAssetId then
                    albumAssetsCache.deviceIds[asset.deviceAssetId] = asset.id
                end
            end
            log:info("processPublishSingleRenditionRenditions: Pre-fetched " .. #assets .. " assets into memory cache.")
        end
    end

    local activeUploadsCount = 0
    local maxConcurrentUploads = 4
    if exportParams and exportParams.maxConcurrentUploads and tonumber(exportParams.maxConcurrentUploads) then
        maxConcurrentUploads = math.max(1, math.floor(tonumber(exportParams.maxConcurrentUploads)))
    end

    local completedQueue = {}
    local LrProgressScope = import 'LrProgressScope'
    local fileProgressScope = LrProgressScope({
        title = "Uploading",
        caption = "Waiting...",
        isCancelable = true,
    })

    local function drainQueue()
        while #completedQueue > 0 do
            local item = table.remove(completedQueue, 1)
            if item.id then
                state.atLeastSomeSuccess = true
                MetadataTask.setImmichAssetId(item.photo, item.id)
                item.rendition:recordPublishedPhotoId(item.id)
                item.rendition:recordPublishedPhotoUrl(immich:getAssetUrl(item.id))
                state.exportedPrimaryByPhoto[item.photo.localIdentifier] = { assetId = item.id, photo = item.photo }
                
                if albumCreationStrategy == "folder" then
                    local folderName = item.photo:getFormattedMetadata("folderName")
                    local folderBasedAlbumId = immich:createOrGetAlbumFolderBased(folderName)
                    if folderBasedAlbumId then
                        immich:addAssetToAlbum(folderBasedAlbumId, item.id)
                    end
                else
                    if albumId and (not albumAssetIds or not util.table_contains(albumAssetIds, item.id)) then
                        immich:addAssetToAlbum(albumId, item.id)
                    end
                end
            else
                table.insert(
                    state.failures,
                    item.photo:getFormattedMetadata("fileName") .. " (" .. (item.errReason or "Upload failed") .. ")"
                )
            end

            -- Advance progress safely on the main thread!
            state.done = state.done + 1
            progressScope:setPortionComplete(state.done, nPhotos)
            if state.done == 1 or state.done % 10 == 0 or state.done == nPhotos then
                log:info("Publish progress: " .. state.done .. "/" .. nPhotos .. " (" .. math.floor(state.done * 100 / nPhotos) .. "%)")
            end

            UploadHelpers.safeDeleteTempFile(item.path)
        end
    end

    for _, rendition in ipairs(renditionsList) do
        if progressScope:isCanceled() then
            break
        end

        -- Drain any completed uploads at the start of each iteration
        drainQueue()

        -- Limit the concurrency: wait for a free upload slot if we reached our limit
        while activeUploadsCount >= maxConcurrentUploads do
            LrTasks.sleep(0.05) -- yield to let active uploads finish
            drainQueue() -- drain completed uploads while waiting
        end

        local success, pathOrMessage = rendition:waitForRender()
        if progressScope:isCanceled() then
            if success then
                UploadHelpers.safeDeleteTempFile(pathOrMessage)
            end
            break
        end

        if success then
            activeUploadsCount = activeUploadsCount + 1

            local photo = rendition.photo
            local deviceAssetId = util.getPhotoDeviceId(photo)

            -- Spawn an asynchronous task for parallel upload
            LrTasks.startAsyncTask(function()
                local function doUpload()
                    local existingId = immich:checkIfAssetExistsEnhanced(
                        photo,
                        deviceAssetId,
                        photo:getFormattedMetadata("fileName"),
                        photo:getFormattedMetadata("dateCreated"),
                        albumAssetsCache
                    )

                    local id, errReason
                    if existingId == nil then
                        id, errReason = immich:uploadAsset(pathOrMessage, deviceAssetId, visibility, fileProgressScope)
                    else
                        -- Always use the current UUID deviceAssetId (not the legacy localIdentifier from the old
                        -- asset) so the new asset can be found by UUID on the next run, breaking the replace cycle.
                        id, errReason = immich:replaceAsset(existingId, pathOrMessage, deviceAssetId, visibility, fileProgressScope)
                    end

                    table.insert(completedQueue, {
                        rendition = rendition,
                        photo = photo,
                        id = id,
                        errReason = errReason,
                        path = pathOrMessage
                    })
                end

                local ok, err = LrTasks.pcall(doUpload)
                if not ok then
                    log:error("Publish upload task crashed: " .. tostring(err))
                    table.insert(completedQueue, {
                        rendition = rendition,
                        photo = photo,
                        id = nil,
                        errReason = "Internal error: " .. tostring(err),
                        path = pathOrMessage
                    })
                end
                activeUploadsCount = activeUploadsCount - 1
            end)
        else
            -- If rendering failed, advance progress instantly
            state.done = state.done + 1
            progressScope:setPortionComplete(state.done, nPhotos)
        end
    end

    -- Block the main thread until all active upload tasks have completed!
    while activeUploadsCount > 0 or #completedQueue > 0 do
        drainQueue()
        LrTasks.sleep(0.05) -- check every 50ms
    end
    fileProgressScope:done()
end

--------------------------------------------------------------------------------
local function runPublishExport(
    immich,
    exportContext,
    progressScope,
    nPhotos,
    exportParams,
    albumCreationStrategy,
    albumId,
    albumAssetIds,
    visibility
)
    local renditions = {}
    for _, rendition in exportContext:renditions({ stopIfCanceled = true }) do
        table.insert(renditions, rendition)
    end

    nPhotos = #renditions
    if nPhotos == 0 then
        return {}, {}, false, {}
    end

    local hostUrl = (exportParams and exportParams.url and exportParams.url ~= "") and exportParams.url or "Immich"
    progressScope:setCaption(util.buildSimpleUploadProgressTitle(nPhotos, "Publishing", hostUrl))

    local batches = UploadHelpers.splitIntoBatches(renditions, exportParams)
    local state = UploadHelpers.createUploadState()

    local useStacking = exportParams.stackOriginalExport
    local mode = exportParams.originalFileMode
    if mode == "edited" or mode == "all" or mode == "original_plus_jpeg_if_edited" or mode == "original_only" then
        useStacking = true
    end

    for _, batch in ipairs(batches) do
        if progressScope:isCanceled() then
            break
        end

        if useStacking then
            processPublishStackOriginalExportRenditions(
                immich,
                batch,
                progressScope,
                nPhotos,
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                visibility,
                state
            )
        else
            processPublishSingleRenditionRenditions(
                immich,
                batch,
                progressScope,
                nPhotos,
                exportParams,
                albumCreationStrategy,
                albumId,
                albumAssetIds,
                visibility,
                state
            )
        end
    end

    if exportParams.stackLrStacks and next(state.exportedPrimaryByPhoto) then
        UploadHelpers.applyLrStacksInImmich(immich, state.exportedPrimaryByPhoto, state.stackWarnings)
    end

    return state.failures, state.stackWarnings, state.atLeastSomeSuccess, state.exportedPrimaryByPhoto
end

--------------------------------------------------------------------------------

function PublishTask.processRenderedPhotos(functionContext, exportContext)
    local exportSession = exportContext and exportContext.exportSession
    if not exportSession then
        return nil
    end

    local nPhotos = exportSession:countRenditions()

    -- Determine if we should only publish the selected photos via a modal prompt
    -- We do this at the absolute beginning BEFORE any network connectivity checks to ensure it is instant!
    local selectedPhotosMap = nil
    local cancelAll = false

    local LrApplication = import 'LrApplication'
    local catalog = LrApplication.activeCatalog()
    local selectedPhotos = catalog:getTargetPhotos()
    
    if selectedPhotos and #selectedPhotos > 0 and #selectedPhotos < nPhotos then
        local LrDialogs = import 'LrDialogs'
        local result = LrDialogs.confirm(
            "Publish Selection or All?",
            "You have " .. #selectedPhotos .. " pending photos selected in your grid.\n"
                .. "Would you like to publish only these selected photos, or publish all " .. nPhotos .. " pending photos in the collection?",
            "Publish Selected (" .. #selectedPhotos .. ")",
            "Cancel",
            "Publish All (" .. nPhotos .. ")"
        )

        if result == "cancel" then
            cancelAll = true
        elseif result == "ok" then
            selectedPhotosMap = {}
            for _, photo in ipairs(selectedPhotos) do
                selectedPhotosMap[photo.localIdentifier] = true
            end
        end
    end

    if cancelAll then
        for photo in exportSession:photosToExport() do
            exportSession:removePhoto(photo)
        end
        return nil
    elseif selectedPhotosMap then
        for photo in exportSession:photosToExport() do
            if not selectedPhotosMap[photo.localIdentifier] then
                exportSession:removePhoto(photo)
            end
        end
    end

    -- Recalculate count after potential removals
    nPhotos = exportSession:countRenditions()
    if nPhotos == 0 then
        return nil
    end

    -- Validate export context and connect to Immich now that the session is pruned
    local _, exportParams, immich = util.validateExportContextAndConnect(exportContext, "Publish")
    if not immich then
        return nil
    end

    -- Only fetch or create the album AFTER pruning the session so we don't block on network
    local albumCreationStrategy, albumId, albumAssetIds = resolvePublishAlbum(immich, exportContext)

    log:info(
        "=== Publish START: "
            .. nPhotos
            .. " photos | url="
            .. tostring(exportParams.url)
            .. " | stackOriginalExport="
            .. tostring(exportParams.stackOriginalExport)
            .. " | stackLrStacks="
            .. tostring(exportParams.stackLrStacks)
            .. " | albumCreationStrategy="
            .. tostring(albumCreationStrategy)
            .. " | lockedFolderMode="
            .. tostring(exportParams.lockedFolderMode)
            .. " ==="
    )

    local progressTitle = (prefs and prefs.url and prefs.url ~= "") and prefs.url or "Immich"
    -- Use LrProgressScope tied to functionContext rather than exportContext:configureProgress.
    -- configureProgress creates a scope managed by LR's render pipeline, which closes the bar
    -- when rendering completes — potentially long before all uploads are done. LrProgressScope
    -- with functionContext stays alive until processRenderedPhotos returns, and is not advanced
    -- by LR's render thread, eliminating both early-close and forward→0→return race conditions.
    local progressScope = LrProgressScope({
        title = util.buildSimpleUploadProgressTitle(nPhotos, "Publishing", progressTitle),
        functionContext = functionContext,
    })

    local visibility = resolveLockedFolder(exportParams)
    local failures, stackWarnings = runPublishExport(
        immich,
        exportContext,
        progressScope,
        nPhotos,
        exportParams,
        albumCreationStrategy,
        albumId,
        albumAssetIds,
        visibility
    )
    progressScope:done()

    log:info(
        "=== Publish DONE: "
            .. nPhotos
            .. " photos | failures="
            .. #failures
            .. " | warnings="
            .. #stackWarnings
            .. " ==="
    )
    util.reportUploadFailuresAndWarnings(failures, stackWarnings)
end

function PublishTask.addCommentToPublishedPhoto(publishSettings, remotePhotoId, commentText) end

function PublishTask.getCommentsFromPublishedCollection(publishSettings, arrayOfPhotoInfo, commentCallback)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in plugin settings.",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end

    for i, photoInfo in ipairs(arrayOfPhotoInfo) do
        -- Get all published Collections where the photo is included.
        local publishedCollections = photoInfo.photo:getContainedPublishedCollections()

        local comments = {}
        for j, publishedCollection in ipairs(publishedCollections) do
            -- Check if the published collection is an Immich collection and still exists on the server.
            if string.sub(publishedCollection:getService():getPluginId(), 1, -3) == _PLUGIN.id then
                log:trace("publishedCollection : " .. publishedCollection:getName() .. " is an Immich collection.")
                if immich:checkIfAlbumExists(publishedCollection:getRemoteId()) then
                    log:trace("... and it exists on the server.")
                    -- Get activities for the photo in the published collection.
                    local activities =
                        immich:getActivities(publishedCollection:getRemoteId(), photoInfo.publishedPhoto:getRemoteId())
                    if activities and type(activities) == "table" then
                        for k, activity in ipairs(activities) do
                            if activity and activity.createdAt then
                                local comment = {}

                                local year, month, day, hour, minute =
                                    string.sub(activity.createdAt, 1, 15):match("(%d+)%-(%d+)%-(%d+)%a(%d+)%:(%d+)")

                                if year and month and day and hour and minute then
                                    -- Convert from date string to EPOC to COCOA
                                    comment.dateCreated = os.time({
                                        year = year,
                                        month = month,
                                        day = day,
                                        hour = hour,
                                        min = minute,
                                    }) - 978307200
                                end
                                comment.commentId = activity.id
                                comment.username = (activity.user and activity.user.email) or ""
                                comment.realname = (activity.user and activity.user.name) or ""

                                if activity.type == "comment" then
                                    comment.commentText = activity.comment or ""
                                    table.insert(comments, comment)
                                elseif activity.type == "like" then
                                    comment.commentText = "Like"
                                    table.insert(comments, comment)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Call Lightroom's callback function to register comments.
        commentCallback({ publishedPhoto = photoInfo, comments = comments })
    end
end

function PublishTask.deletePhotosFromPublishedCollection(
    publishSettings,
    arrayOfPhotoIds,
    deletedCallback,
    localCollectionId
)
    if util.nilOrEmpty(publishSettings.url) or util.nilOrEmpty(publishSettings.apiKey) then
        ErrorHandler.handleError(
            "Configure Immich in plugin settings.",
            "deletePhotosFromPublishedCollection: URL or API key not set"
        )
        return nil
    end
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in plugin settings.",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end

    local delete = LrDialogs.promptForActionWithDoNotShow({
        actionPrefKey = "immichDeletePhotosTrashBehavior",
        message = "Delete photos",
        info = "Should removed photos be trashed in Immich?",
        verbBtns = {
            { verb = "no", label = "No" },
            { verb = "only_if_not_in_album", label = "If not included in any album" },
            { verb = "always", label = "Yes (dangerous!)" },
        },
    })
    if delete == nil then
        return nil
    end

    local catalog = LrApplication.activeCatalog()
    if not catalog then
        ErrorHandler.handleError(
            "Lightroom catalog not available.",
            "deletePhotosFromPublishedCollection: cannot access catalog"
        )
        return nil
    end
    local publishedCollection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionId)
    if not publishedCollection then
        ErrorHandler.handleError(
            "Collection not found.",
            "deletePhotosFromPublishedCollection: published collection not found"
        )
        return nil
    end
    local publishedPhotos = publishedCollection:getPublishedPhotos()

    local notExistingAlbums = {}

    for _, publishedPhoto in ipairs(publishedPhotos) do
        if util.table_contains(arrayOfPhotoIds, publishedPhoto:getRemoteId()) then
            local photoRemoteId = publishedPhoto:getRemoteId()
            log:trace("Photo " .. photoRemoteId .. " is in the list to be deleted.")

            local folderName = publishedPhoto:getPhoto():getFormattedMetadata("folderName")
            log:trace("Photo is in folder: " .. folderName)

            local albumId = nil
            local albumCreationStrategy =
                publishedCollection:getCollectionInfoSummary().collectionSettings.albumCreationStrategy
            if albumCreationStrategy == nil then
                albumCreationStrategy = "collection" -- Default strategy for old collections.
            end

            if albumCreationStrategy == "folder" then
                local albums = immich:getAlbumsByNameFolderBased(folderName)
                log:trace("Album found for folder based strategy: " .. util.dumpTable(albums))
                if albums ~= nil and #albums == 1 then
                    albumId = albums[1].value
                elseif not util.table_contains(notExistingAlbums, folderName or "(unknown folder)") then
                    table.insert(notExistingAlbums, folderName or "(unknown folder)")
                end
            else
                albumId = publishedCollection:getRemoteId()
            end

            log:trace("Album id to remove from: " .. albumId)

            local removeFromAlbumSuccess = false
            if albumId ~= nil then
                removeFromAlbumSuccess = immich:removeAssetFromAlbum(albumId, photoRemoteId)
            end

            local deletionSuccess = true
            if delete == "always" then
                deletionSuccess = immich:deleteAsset(photoRemoteId)
            elseif delete == "only_if_not_in_album" then
                if not immich:checkIfAssetIsInAnAlbum(photoRemoteId) then
                    deletionSuccess = immich:deleteAsset(photoRemoteId)
                end
            end
            -- delete == 'no': only remove from album, do not trash
            if not deletionSuccess then
                ErrorHandler.handleError(
                    "Failed to delete asset (check logs)",
                    "Failed to delete asset " .. photoRemoteId .. " from Immich"
                )
            end

            if removeFromAlbumSuccess and deletionSuccess then
                log:trace("Successfully removed photo " .. photoRemoteId .. " from album " .. tostring(albumId))
                deletedCallback(photoRemoteId)
            end
        end
    end

    if #notExistingAlbums > 0 then
        LrDialogs.message(
            "Some albums not found",
            "The following albums were not found on the Immich server,"
                .. " but the photos were removed from the collection: \n"
                .. table.concat(notExistingAlbums, "\n"),
            "info"
        )
    end
end

function PublishTask.deletePublishedCollection(publishSettings, info)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in plugin settings.",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end

    -- remoteId is nil, if the collection isn't yet published.
    if info.remoteId ~= nil and info.remoteId ~= "" then
        if not immich:checkIfAlbumExists(info.remoteId) then
            log:trace(
                "deletePublishedCollection: album does not exist on server, skip delete: " .. tostring(info.remoteId)
            )
        else
            local ok = immich:deleteAlbum(info.remoteId)
            if not ok then
                ErrorHandler.handleError(
                    "Could not delete album on Immich. Check logs.",
                    "deletePublishedCollection: failed to delete album " .. tostring(info.remoteId)
                )
            end
        end
    end
end

function PublishTask.renamePublishedCollection(publishSettings, info)
    local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
    if not immich:checkConnectivity() then
        ErrorHandler.handleError(
            "Immich connection not working. Check URL and API key in plugin settings.",
            "Immich connection not working, probably due to wrong url and/or apiKey. Export stopped."
        )
        return nil
    end

    -- remoteId is nil, if the collection isn't yet published.
    if info.remoteId ~= nil and info.remoteId ~= "" and info.name and info.name ~= "" then
        local ok = immich:renameAlbum(info.remoteId, info.name)
        if not ok then
            ErrorHandler.handleError(
                "Could not rename album on Immich. Check logs.",
                "renamePublishedCollection: failed to rename album " .. tostring(info.remoteId)
            )
        end
    end
end

function PublishTask.shouldDeletePhotosFromServiceOnDeleteFromCatalog(publishSettings, nPhotos)
    return nil -- Show builtin Lightroom dialog.
end

function PublishTask.validatePublishedCollectionName(name)
    return true, "" -- TODO
end

function PublishTask.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = "default",
        defaultCollectionCanBeDeleted = true,
        canAddCollection = true,
        -- Allow unlimited depth of collection sets, as requested by user.
        -- maxCollectionSetDepth = 0,
    }
end

function PublishTask.viewForCollectionSettings(f, publishSettings, info)
    if info.publishedCollection ~= nil then
        return f:row({}) -- No settings for existing published collections.
    end

    info.pluginContext.albumCreationStrategy = "collection"
    info.pluginContext.selectedAlbum = 0
    info.pluginContext.immichAlbums = { { title = "Please select", value = 0 } }

    LrTasks.startAsyncTask(function()
        local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
        local albums = immich:getAlbumsWODate()
        if albums == nil then
            albums = {}
        end
        table.insert(albums, 1, { title = "Please select", value = 0 })
        info.pluginContext.immichAlbums = albums
    end)

    local share = LrView.share
    local bind = LrView.bind

    local result = f:group_box({
        bind_to_object = info.pluginContext,
        title = "Immich Album Settings",
        fill_horizontal = 1,
        f:column({
            spacing = share("inter_control_spacing"),
            f:radio_button({
                title = "Create new album from collection name",
                checked_value = "collection",
                value = bind("albumCreationStrategy"),
            }),
            f:radio_button({
                title = "Create albums based on folder names",
                checked_value = "folder",
                value = bind("albumCreationStrategy"),
            }),
            f:row({
                f:radio_button({
                    title = "Use existing album",
                    checked_value = "existing",
                    value = bind("albumCreationStrategy"),
                }),
                f:popup_menu({
                    items = bind("immichAlbums"),
                    value = bind("selectedAlbum"), -- Preselect "Please select"
                    width = share("field_width"),
                    enabled = bind("albumCreationStrategy", { "existing" }),
                }),
            }),
        }),
    })

    return result
end

function PublishTask.endDialogForCollectionSettings(publishSettings, info)
    log:trace("endDialogForCollectionSettings called")
    local props = info.pluginContext
    if info.why == "ok" then
        if props.albumCreationStrategy ~= nil then
            if props.albumCreationStrategy == "existing" and props.selectedAlbum ~= 0 then
                log:trace("User selected to bind collection to existing album with id " .. props.selectedAlbum)
                info.collectionSettings.albumCreationStrategy = "existing"
                info.collectionSettings.remoteId = props.selectedAlbum
            elseif props.albumCreationStrategy == "existing" and props.selectedAlbum == 0 then
                ErrorHandler.handleError("No album selected", "No album selected")
            else
                log:trace("Setting album creation strategy to: " .. props.albumCreationStrategy)
                info.collectionSettings.albumCreationStrategy = props.albumCreationStrategy
            end
        elseif info.collectionSettings.albumCreationStrategy == nil then
            log:trace("No album creation strategy set, defaulting to 'collection'")
            info.collectionSettings.albumCreationStrategy = "collection" -- Default strategy for old collections.
        else
            log:trace("Keeping existing album creation strategy: " .. info.collectionSettings.albumCreationStrategy)
        end
    end
end

function PublishTask.updateCollectionSettings(publishSettings, info)
    log:trace("updateCollectionSettings called")
    if not info or not info.collectionSettings then
        return
    end
    local props = info.collectionSettings
    if props.albumCreationStrategy == "existing" and props.remoteId then
        local immich = ImmichAPI:new(publishSettings.url, publishSettings.apiKey)
        if not immich:checkConnectivity() then
            log:warn("updateCollectionSettings: Immich connection not available")
            return
        end
        log:trace("Binding collection to existing album with id " .. tostring(props.remoteId))
        local name = immich:getAlbumNameById(props.remoteId)
        local url = immich:getAlbumUrl(props.remoteId)
        if not name then
            name = "Album " .. tostring(props.remoteId)
        end
        if not url then
            url = ""
        end
        log:trace("Setting collection name to " .. tostring(name) .. ", url to " .. tostring(url))
        local catalog = LrApplication.activeCatalog()
        if catalog and info.publishedCollection then
            catalog:withWriteAccessDo("Update published collection info", function()
                info.publishedCollection:setRemoteId(props.remoteId)
                info.publishedCollection:setRemoteUrl(url)
                info.publishedCollection:setName(name)
            end)
        end
    end
end
