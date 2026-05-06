package de.adleraufmasse.atool

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val downloadsChannel = "de.adleraufmasse.atool/downloads"
    private val pickDirectoryRequestCode = 4711
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            downloadsChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDownloadDirectory" -> pickDownloadDirectory(result)
                "saveFileToDirectory" -> saveFileToDirectory(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pickDownloadDirectory(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("PICKER_ACTIVE", "Ordnerauswahl läuft bereits.", null)
            return
        }

        pendingPickResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }

        startActivityForResult(intent, pickDirectoryRequestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != pickDirectoryRequestCode) return

        val result = pendingPickResult
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result?.success(null)
            return
        }

        val uri = data.data!!
        val flags = data.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )

        try {
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
            // Some document providers grant access only for the current session.
        }

        result?.success(
            mapOf(
                "uri" to uri.toString(),
                "name" to getDirectoryName(uri),
            )
        )
    }

    private fun saveFileToDirectory(call: MethodCall, result: MethodChannel.Result) {
        val directoryUri = call.argument<String>("directoryUri")
        val fileName = call.argument<String>("fileName")
        val bytes = call.argument<ByteArray>("bytes")

        if (directoryUri.isNullOrBlank() || fileName.isNullOrBlank() || bytes == null) {
            result.error("INVALID_ARGUMENTS", "Download-Daten sind unvollständig.", null)
            return
        }

        try {
            val treeUri = Uri.parse(directoryUri)
            val directory = DocumentFile.fromTreeUri(this, treeUri)

            if (directory == null || !directory.exists() || !directory.canWrite()) {
                result.error("NO_WRITE_ACCESS", "Kein Schreibzugriff auf diesen Ordner.", null)
                return
            }

            directory.findFile(fileName)?.delete()

            val file = directory.createFile("application/octet-stream", fileName)
            if (file == null) {
                result.error("CREATE_FAILED", "Datei konnte nicht erstellt werden.", null)
                return
            }

            contentResolver.openOutputStream(file.uri, "w")?.use { stream ->
                stream.write(bytes)
                stream.flush()
            } ?: run {
                result.error("OPEN_FAILED", "Datei konnte nicht geöffnet werden.", null)
                return
            }

            result.success(true)
        } catch (error: Exception) {
            result.error("SAVE_FAILED", error.localizedMessage, null)
        }
    }

    private fun getDirectoryName(uri: Uri): String {
        val treeDocumentId = DocumentsContract.getTreeDocumentId(uri)
        val rawName = treeDocumentId.substringAfterLast(':', treeDocumentId)
        return rawName.ifBlank { "Ausgewählter Ordner" }
    }
}
