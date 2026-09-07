package com.example.shenliyuan

import android.content.Context
import android.os.StatFs
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * 更新包的唯一下载实现。每个 Range 段写入独立文件，避免并发写一个 part 文件；
 * 当链路不严格支持 206 / Content-Range 时，立即退回单连接续传。
 */
internal class UpdatePackageDownloader(private val context: Context) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.MINUTES)
        .build()
    private val lock = Any()
    private var lastPersistNanos = System.nanoTime()
    private var lastPersistBytes = 0L

    suspend fun prepare(release: UpdateRelease, onProgress: (UpdateDownloadManifest) -> Unit) =
        withContext(Dispatchers.IO) {
            release.validate()
            ensureEnoughSpace(release)
            var manifest = UpdateManifestStore.read(context, release) ?: newManifest(release)
            if (manifest.state == "ready" && validReadyFile(manifest)) return@withContext manifest
            manifest.state = "downloading"
            manifest.errorCode = null
            UpdateManifestStore.write(context, manifest)
            onProgress(manifest)
            try {
                manifest = try {
                    parallelDownload(manifest, onProgress)
                } catch (error: RangeUnsupportedException) {
                    Log.i(TAG, "update_parallel_fallback reason=${error.message}")
                    removeSegmentFiles(release)
                    val fallback = manifest.copy(segments = mutableListOf())
                    singleStreamDownload(fallback, onProgress)
                }
                manifest.state = "verifying"
                UpdateManifestStore.write(context, manifest)
                onProgress(manifest)
                val apk = mergeAndVerify(manifest)
                manifest.state = "ready"
                manifest.apkPath = apk.canonicalPath
                manifest.errorCode = null
                manifest.segments.clear()
                UpdateManifestStore.write(context, manifest)
                removeSegmentFiles(release)
                onProgress(manifest)
                Log.i(TAG, "update_download_ready version=${release.versionCode}")
                manifest
            } catch (error: Exception) {
                manifest.state = if (error is UpdateNetworkException) "paused" else "failed"
                manifest.errorCode = error.javaClass.simpleName
                UpdateManifestStore.write(context, manifest)
                onProgress(manifest)
                throw error
            }
        }

    private suspend fun parallelDownload(
        manifest: UpdateDownloadManifest,
        onProgress: (UpdateDownloadManifest) -> Unit,
    ): UpdateDownloadManifest = coroutineScope {
        val release = manifest.release
        val segments = if (manifest.segments.isEmpty()) splitSegments(release.fileSize) else manifest.segments
        manifest.segments.clear()
        manifest.segments.addAll(segments)
        manifest.segments.forEachIndexed { index, segment ->
            val file = segmentFile(release, index)
            val actual = if (file.isFile) file.length() else 0L
            segment.downloaded = actual.coerceAtMost(segment.end - segment.start + 1)
        }
        UpdateManifestStore.write(context, manifest)
        Log.i(TAG, "update_download_started version=${release.versionCode} segments=${manifest.segments.size}")
        manifest.segments.mapIndexed { index, segment ->
            async { downloadSegment(manifest, index, segment, onProgress) }
        }.awaitAll()
        manifest
    }

    private suspend fun downloadSegment(
        manifest: UpdateDownloadManifest,
        index: Int,
        segment: UpdateSegment,
        onProgress: (UpdateDownloadManifest) -> Unit,
    ) = withContext(Dispatchers.IO) {
        val expectedLength = segment.end - segment.start + 1
        if (segment.downloaded == expectedLength) return@withContext
        val file = segmentFile(manifest.release, index)
        repeat(3) { attempt ->
            try {
                val start = segment.start + segment.downloaded
                val request = Request.Builder().url(manifest.release.downloadUrl)
                    .header("Range", "bytes=$start-${segment.end}").build()
                client.newCall(request).execute().use { response ->
                    if (response.code != 206) throw RangeUnsupportedException("http_${response.code}")
                    val range = response.header("Content-Range")
                        ?: throw RangeUnsupportedException("content_range_missing")
                    validateContentRange(range, start, segment.end, manifest.release.fileSize)
                    val body = response.body ?: throw UpdateNetworkException("empty_body")
                    body.byteStream().use { input ->
                        FileOutputStream(file, true).use { output ->
                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                if (segment.downloaded + count > expectedLength) {
                                    throw RangeUnsupportedException("response_overflow")
                                }
                                output.write(buffer, 0, count)
                                updateProgress(manifest, segment, count.toLong(), onProgress)
                            }
                            output.fd.sync()
                        }
                    }
                }
                if (segment.downloaded != expectedLength) throw UpdateNetworkException("segment_short_read")
                return@withContext
            } catch (error: RangeUnsupportedException) {
                throw error
            } catch (error: Exception) {
                if (attempt == 2) throw UpdateNetworkException("segment_$index: ${error.message}")
                Log.i(TAG, "update_segment_retry segment=$index attempt=${attempt + 2}")
                Thread.sleep(1_000L shl attempt)
            }
        }
    }

    private fun updateProgress(
        manifest: UpdateDownloadManifest,
        segment: UpdateSegment,
        added: Long,
        onProgress: (UpdateDownloadManifest) -> Unit,
    ) = synchronized(lock) {
        segment.downloaded += added
        val now = System.nanoTime()
        val previousBytes = manifest.bytesPerSecond
        // 以 500ms 限流写 manifest / 通知，避免每个网络 chunk 都造成 I/O。
        val elapsed = (now - lastPersistNanos).coerceAtLeast(1)
        if (now - lastPersistNanos >= 500_000_000L) {
            val bytes = manifest.receivedBytes()
            manifest.bytesPerSecond = ((bytes - lastPersistBytes) * 1_000_000_000L / elapsed)
                .coerceAtLeast(0)
            lastPersistBytes = bytes
            lastPersistNanos = now
            UpdateManifestStore.write(context, manifest)
            onProgress(manifest)
        } else if (previousBytes < 0) {
            manifest.bytesPerSecond = 0
        }
    }

    private fun singleStreamDownload(
        manifest: UpdateDownloadManifest,
        onProgress: (UpdateDownloadManifest) -> Unit,
    ): UpdateDownloadManifest {
        val release = manifest.release
        val file = singleFile(release)
        var downloaded = if (file.isFile) file.length() else 0L
        if (downloaded > release.fileSize) {
            file.delete()
            downloaded = 0
        }
        // 分片回退后若单流文件已经完整，不再发送一个会得到 416 的 Range 请求。
        if (downloaded == release.fileSize) {
            manifest.segments.clear()
            manifest.segments += UpdateSegment(0, release.fileSize - 1, downloaded)
            return manifest
        }
        val request = Request.Builder().url(release.downloadUrl).apply {
            if (downloaded > 0) header("Range", "bytes=$downloaded-")
        }.build()
        client.newCall(request).execute().use { response ->
            if (response.code == 416) {
                // 服务器对陈旧断点拒绝 Range：删掉不完整文件，改为完整单流重下。
                file.delete()
                manifest.segments.clear()
                return singleStreamDownload(manifest, onProgress)
            }
            if (response.code != 200 && response.code != 206) {
                throw UpdateNetworkException("single_http_${response.code}")
            }
            if (response.code == 206) {
                validateContentRange(
                    response.header("Content-Range")
                        ?: throw UpdateNetworkException("single_content_range_missing"),
                    downloaded,
                    release.fileSize - 1,
                    release.fileSize,
                )
            }
            val append = response.code == 206 && downloaded > 0
            if (!append) downloaded = 0
            val body = response.body ?: throw UpdateNetworkException("single_empty_body")
            body.byteStream().use { input ->
                FileOutputStream(file, append).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (downloaded + count > release.fileSize) {
                            throw UpdateNetworkException("single_response_overflow")
                        }
                        output.write(buffer, 0, count)
                        downloaded += count
                        manifest.segments.clear()
                        manifest.segments += UpdateSegment(0, release.fileSize - 1, downloaded)
                        updateProgress(manifest, manifest.segments.single(), 0, onProgress)
                    }
                    output.fd.sync()
                }
            }
        }
        if (downloaded != release.fileSize) throw UpdateNetworkException("single_short_read")
        return manifest
    }

    private fun mergeAndVerify(manifest: UpdateDownloadManifest): File {
        val release = manifest.release
        val merge = mergeFile(release)
        if (merge.exists()) merge.delete()
        val digest = MessageDigest.getInstance("SHA-256")
        FileOutputStream(merge).use { output ->
            if (manifest.segments.size == 1 && singleFile(release).isFile) {
                copyWithDigest(singleFile(release), output, digest)
            } else {
                manifest.segments.indices.forEach { index ->
                    val segment = manifest.segments[index]
                    val file = segmentFile(release, index)
                    if (!file.isFile || file.length() != segment.end - segment.start + 1) {
                        throw IllegalStateException("segment_$index 长度不完整")
                    }
                    copyWithDigest(file, output, digest)
                }
            }
            output.fd.sync()
        }
        if (merge.length() != release.fileSize || digest.digest().toHex() != release.sha256.lowercase()) {
            merge.delete()
            throw IllegalStateException("checksum_mismatch")
        }
        val apk = apkFile(release)
        if (apk.exists()) apk.delete()
        if (!merge.renameTo(apk)) throw IllegalStateException("apk_rename_failed")
        singleFile(release).delete()
        return apk
    }

    private fun copyWithDigest(source: File, target: FileOutputStream, digest: MessageDigest) {
        FileInputStream(source).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                target.write(buffer, 0, count)
                digest.update(buffer, 0, count)
            }
        }
    }

    private fun newManifest(release: UpdateRelease) = UpdateDownloadManifest(
        release = release,
        state = "queued",
        segments = splitSegments(release.fileSize),
    )

    private fun splitSegments(size: Long): MutableList<UpdateSegment> {
        val count = when {
            size < 16L * 1024 * 1024 -> 1
            size <= 32L * 1024 * 1024 -> 2
            else -> 4
        }
        return MutableList(count) { index ->
            val start = size * index / count
            val end = size * (index + 1) / count - 1
            UpdateSegment(start, end, 0)
        }
    }

    private fun validateContentRange(value: String, start: Long, end: Long, total: Long) {
        val match = CONTENT_RANGE.matchEntire(value.trim())
            ?: throw RangeUnsupportedException("content_range_invalid")
        if (match.groupValues[1].toLong() != start || match.groupValues[2].toLong() != end ||
            match.groupValues[3].toLong() != total) {
            throw RangeUnsupportedException("content_range_mismatch")
        }
    }

    private fun validReadyFile(manifest: UpdateDownloadManifest): Boolean {
        val file = manifest.apkPath?.let(::File) ?: apkFile(manifest.release)
        return file.isFile && file.length() == manifest.release.fileSize &&
            sha256(file) == manifest.release.sha256.lowercase()
    }

    private fun sha256(file: File): String = MessageDigest.getInstance("SHA-256").also { digest ->
        FileInputStream(file).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
    }.digest().toHex()

    private fun ensureEnoughSpace(release: UpdateRelease) {
        val stats = StatFs(UpdateManifestStore.rootDirectory(context).path)
        val available = stats.availableBytes
        val required = (release.fileSize * 2.2).toLong()
        if (available < required) throw IllegalStateException("storage_insufficient_required_$required")
    }

    private fun segmentFile(release: UpdateRelease, index: Int) = File(
        UpdateManifestStore.rootDirectory(context), "${release.sha256.lowercase()}.segment-$index.part")
    private fun singleFile(release: UpdateRelease) = File(
        UpdateManifestStore.rootDirectory(context), "${release.sha256.lowercase()}.single.part")
    private fun mergeFile(release: UpdateRelease) = File(
        UpdateManifestStore.rootDirectory(context), "${release.sha256.lowercase()}.merge.part")
    private fun apkFile(release: UpdateRelease) = File(
        UpdateManifestStore.rootDirectory(context), "${release.sha256.lowercase()}.apk")
    private fun removeSegmentFiles(release: UpdateRelease) {
        UpdateManifestStore.rootDirectory(context).listFiles()
            ?.filter { it.name.startsWith(release.sha256.lowercase()) && it.name.contains(".segment-") }
            ?.forEach { it.delete() }
    }

    private class RangeUnsupportedException(message: String) : Exception(message)
    private class UpdateNetworkException(message: String) : Exception(message)

    private companion object {
        const val TAG = "UpdateDownload"
        val CONTENT_RANGE = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)")
        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    }
}
