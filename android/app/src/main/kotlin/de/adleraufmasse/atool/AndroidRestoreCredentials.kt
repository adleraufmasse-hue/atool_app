package de.adleraufmasse.atool

import android.app.Activity
import android.os.Build
import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CreateRestoreCredentialRequest
import androidx.credentials.CreateRestoreCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetRestoreCredentialOption
import androidx.credentials.RestoreCredential
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.NoCredentialException
import androidx.credentials.exceptions.restorecredential.E2eeUnavailableException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

internal class AndroidRestoreCredentials(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val manager by lazy { CredentialManager.create(activity) }
    private val channel = MethodChannel(messenger, "de.adleraufmasse.atool/restore_credentials")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "isSupported") {
                result.success(isSupported())
                return@setMethodCallHandler
            }
            if (call.method !in setOf("create", "get", "clear")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (!isSupported()) {
                result.error("RESTORE_UNAVAILABLE", null, null)
                return@setMethodCallHandler
            }
            scope.launch {
                try {
                    val response = withTimeout(5_000) {
                        when (call.method) {
                            "create" -> create(requireNotNull(call.arguments as? String))
                            "get" -> get(requireNotNull(call.arguments as? String))
                            else -> clear()
                        }
                    }
                    result.success(response)
                } catch (_: TimeoutCancellationException) {
                    result.error("RESTORE_TIMEOUT", null, null)
                } catch (error: kotlinx.coroutines.CancellationException) {
                    throw error
                } catch (_: Exception) {
                    result.error("RESTORE_UNAVAILABLE", null, null)
                }
            }
        }
    }

    private fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P

    private suspend fun create(options: String): String {
        val response = try {
            manager.createCredential(activity, CreateRestoreCredentialRequest(options))
        } catch (_: E2eeUnavailableException) {
            manager.createCredential(
                activity,
                CreateRestoreCredentialRequest(options, isCloudBackupEnabled = false),
            )
        }
        return (response as CreateRestoreCredentialResponse).responseJson
    }

    private suspend fun get(options: String): String? {
        return try {
            val request = GetCredentialRequest(listOf(GetRestoreCredentialOption(options)))
            val credential = manager.getCredential(activity, request).credential as RestoreCredential
            credential.authenticationResponseJson
        } catch (_: NoCredentialException) {
            null
        }
    }

    private suspend fun clear(): Boolean {
        manager.clearCredentialState(
            ClearCredentialStateRequest(ClearCredentialStateRequest.TYPE_CLEAR_RESTORE_CREDENTIAL)
        )
        try {
            manager.clearCredentialState(ClearCredentialStateRequest())
        } catch (_: ClearCredentialException) {
            // The restore key is already cleared. The app has no other provider session.
        }
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }
}
