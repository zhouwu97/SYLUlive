package com.example.shenliyuan

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import org.robolectric.Shadows.shadowOf
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.io.IOException

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class AcademicArchiveStoreTest {
    private lateinit var context: Context
    private lateinit var provider: DownloadsProvider
    @Before fun setup() {
        context = ApplicationProvider.getApplicationContext()
        provider = DownloadsProvider(File(context.cacheDir, "archive-test.json"))
        ShadowContentResolver.registerProviderInternal("media", provider)
    }
    @Test fun publishesUtf8ToPublicDownloadFolder() {
        val output = ByteArrayOutputStream()
        shadowOf(context.contentResolver).registerOutputStream(Uri.parse("content://media/external/downloads/1"), output)
        val result = AcademicArchiveStore.save(context, "课表.json", "[{\"课程\":\"数学\"}]", "课表存档")
        assertEquals("Download/沈理校园/课表存档/课表 (1).json", result["savedPath"])
        assertEquals("Download/沈理校园/课表存档/", provider.inserted!!.getAsString(MediaStore.MediaColumns.RELATIVE_PATH))
        assertEquals(1, provider.inserted!!.getAsInteger(MediaStore.MediaColumns.IS_PENDING))
        assertEquals(0, provider.published!!.getAsInteger(MediaStore.MediaColumns.IS_PENDING))
        assertEquals("[{\"课程\":\"数学\"}]", output.toString("UTF-8"))
        assertFalse(provider.deleted)
    }
    @Test fun removesUnfinishedFileOnWriteFailure() {
        shadowOf(context.contentResolver).registerOutputStream(Uri.parse("content://media/external/downloads/1"), object : OutputStream() {
            override fun write(value: Int) { throw IOException("disk full") }
        })
        assertThrows(IOException::class.java) {
            AcademicArchiveStore.save(context, "考试.json", "{}", "考试存档")
        }
        assertTrue(provider.deleted)
        assertNull(provider.published)
    }
    @Test fun rejectsPathTraversal() {
        assertThrows(IllegalArgumentException::class.java) {
            AcademicArchiveStore.save(context, "../课表.json", "[]", "课表存档")
        }
        assertNull(provider.inserted)
    }
    @Test @Config(sdk = [28]) fun oldAndroidRequestsSystemFilePicker() {
        assertEquals(true, AcademicArchiveStore.save(context, "考试.json", "{}", "考试存档")["legacy"])
        assertNull(provider.inserted)
    }
    class DownloadsProvider(val file: File) : ContentProvider() {
        var inserted: ContentValues? = null
        var published: ContentValues? = null
        var deleted = false
        var failWrite = false
        override fun onCreate() = true
        override fun getType(uri: Uri) = "application/json"
        override fun insert(uri: Uri, values: ContentValues?): Uri {
            inserted = ContentValues(values)
            return Uri.parse("content://media/external/downloads/1")
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
            if (failWrite) return null
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_READ_WRITE)
        }
        override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?): Int {
            published = ContentValues(values)
            return 1
        }
        override fun delete(uri: Uri, selection: String?, args: Array<out String>?): Int { deleted = true; return 1 }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor {
            return MatrixCursor(arrayOf(MediaStore.MediaColumns.DISPLAY_NAME)).apply { addRow(arrayOf("课表 (1).json")) }
        }
    }
}
