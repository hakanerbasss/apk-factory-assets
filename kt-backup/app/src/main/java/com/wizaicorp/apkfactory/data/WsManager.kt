package com.wizaicorp.apkfactory.data

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import okhttp3.*
import org.json.JSONObject

sealed class WsEvent {
    data class Log(val text: String)                            : WsEvent()
    data class Status(val text: String)                         : WsEvent()
    data class BuildDone(val success: Boolean, val project: String, val apkPath: String = "") : WsEvent()
    data class ProjectDone(val success: Boolean, val name: String)          : WsEvent()
    data class TaskDone(val success: Boolean, val text: String = "", val apkPath: String = "", val project: String = "") : WsEvent()
    data class UserAction(val text: String) : WsEvent()
    data class NextTask(val task: String, val project: String) : WsEvent()
    data class ChainTask(val task: String, val project: String) : WsEvent()
    data class Prompt(val promptType: String, val errorMsg: String = "")    : WsEvent()
    data class Projects(val list: List<ProjectInfo>)                        : WsEvent()
    data class ApiList(val list: List<ApiInfo>)                             : WsEvent()
    data class KeystoreList(val list: List<KeystoreInfo>)                   : WsEvent()
    data class BackupList(val list: List<String>)                           : WsEvent()
    data class ApkList(val list: List<ApkInfo>)                             : WsEvent()
    data class Settings(val data: Map<String, String>)                      : WsEvent()
    data class FileContent(val path: String, val content: String)           : WsEvent()
    data class SystemInfo(val data: Map<String, Any>)                       : WsEvent()
    data class Providers(val list: List<Map<String, Any>>)                  : WsEvent()
    object Connected    : WsEvent()
    object Disconnected : WsEvent()
    data class PromptContent(val name: String, val content: String, val isDefault: Boolean) : WsEvent()
    data class DepsStatus(val ok: Boolean, val updated: List<String>, val missing: List<String>) : WsEvent()
    data class VersionInfo(val scriptVersion: String, val promptVersion: String, val hasUpdate: Boolean, val changelog: List<String>) : WsEvent()
    data class PromptArchives(val list: List<String>) : WsEvent()
    data class Error(val msg: String) : WsEvent()
    data class ExportDone(val path: String, val format: String, val text: String) : WsEvent()
}

data class ProjectInfo(val name: String, val packageName: String, val keystore: String = "", val alias: String = "")
data class ApiInfo(val name: String, val keyPreview: String, val hasKey: Boolean)
data class KeystoreInfo(val name: String, val path: String, val alias: String, val project: String, val size: Long)
data class ApkInfo(val name: String, val project: String, val path: String, val size: Long, val date: String, val fileType: String = "apk")

object WsManager {
    private val client = OkHttpClient()
    private val scope  = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var webSocket: WebSocket? = null

    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected.asStateFlow()

    private val _events = MutableSharedFlow<WsEvent>(replay = 10, extraBufferCapacity = 100)
    val events: SharedFlow<WsEvent> = _events.asSharedFlow()

    fun connect() {
        val request = Request.Builder().url("ws://127.0.0.1:8765").build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, r: Response) {
                _connected.value = true
                scope.launch { _events.emit(WsEvent.Connected) }
            }
            override fun onMessage(ws: WebSocket, text: String) {
                scope.launch {
                    try {
                        val json = JSONObject(text)
                        when (json.getString("type")) {
                            "log"          -> _events.emit(WsEvent.Log(json.getString("text")))
                            "status"       -> _events.emit(WsEvent.Status(json.getString("text")))
                            "connected"    -> _events.emit(WsEvent.Status(json.getString("text")))
                            "build_done"   -> _events.emit(WsEvent.BuildDone(
                                json.getBoolean("success"),
                                json.optString("project",""),
                                json.optString("apk_path","")))
                            "project_done" -> _events.emit(WsEvent.ProjectDone(json.getBoolean("success"), json.optString("name","")))
                            "next_task"    -> _events.emit(WsEvent.NextTask(json.optString("task",""), json.optString("project","")))
                            "chain_task"   -> _events.emit(WsEvent.ChainTask(json.optString("task",""), json.optString("project","")))
                            "user_action"  -> _events.emit(WsEvent.UserAction(json.optString("text","")))
                            "task_done"    -> _events.emit(WsEvent.TaskDone(
                                json.getBoolean("success"),
                                json.optString("text",""),
                                json.optString("apk_path",""),
                                json.optString("project","")))
                            "prompt"       -> _events.emit(WsEvent.Prompt(json.getString("prompt_type"), json.optString("error_msg","")))
                            "projects"     -> {
                                val arr = json.getJSONArray("data")
                                _events.emit(WsEvent.Projects((0 until arr.length()).map {
                                    val o = arr.getJSONObject(it)
                                    ProjectInfo(o.getString("name"), o.optString("package",""),
                                        o.optString("keystore",""), o.optString("alias",""))
                                }))
                            }
                            "api_list"     -> {
                                val arr = json.getJSONArray("data")
                                _events.emit(WsEvent.ApiList((0 until arr.length()).map {
                                    val o = arr.getJSONObject(it)
                                    ApiInfo(o.getString("name"), o.optString("key_preview",""), o.optBoolean("has_key",false))
                                }))
                            }
                            "keystores"    -> {
                                val arr = json.getJSONArray("data")
                                _events.emit(WsEvent.KeystoreList((0 until arr.length()).map {
                                    val o = arr.getJSONObject(it)
                                    KeystoreInfo(o.getString("name"), o.optString("path",""),
                                        o.optString("alias",""), o.optString("project",""), o.optLong("size",0))
                                }))
                            }
                            "backups"      -> {
                                val arr = json.getJSONArray("data")
                                _events.emit(WsEvent.BackupList((0 until arr.length()).map { arr.getString(it) }))
                            }
                            "apk_list"     -> {
                                val arr = json.getJSONArray("data")
                                _events.emit(WsEvent.ApkList((0 until arr.length()).map {
                                    val o = arr.getJSONObject(it)
                                    ApkInfo(o.getString("name"), o.optString("project",""),
                                        o.optString("path",""), o.optLong("size",0),
                                        o.optString("date",""), o.optString("type","apk"))
                                }))
                            }
                            "providers"    -> {
                                val arr = json.getJSONArray("data")
                                val list = (0 until arr.length()).map { i ->
                                    val item = arr.getJSONObject(i)
                                    val models = mutableListOf<String>()
                                    val modelsArr = item.optJSONArray("models")
                                    if (modelsArr != null) for (j in 0 until modelsArr.length()) models.add(modelsArr.getString(j))
                                    val modelInfos = mutableMapOf<String,String>()
                                    val infosObj = item.optJSONObject("model_infos")
                                    infosObj?.keys()?.forEach { k -> modelInfos[k] = infosObj.optString(k,"") }
                                    mapOf<String, Any>("name" to item.getString("name"), "model" to item.optString("model",""), "models" to models, "model_infos" to modelInfos, "hasKey" to item.optBoolean("hasKey",false))
                                }
                                _events.emit(WsEvent.Providers(list))
                            }
                            "settings"     -> {
                                val obj = json.getJSONObject("data")
                                val map = mutableMapOf<String,String>()
                                obj.keys().forEach { k -> map[k] = obj.optString(k,"") }
                                _events.emit(WsEvent.Settings(map))
                            }
                            "file_content" -> _events.emit(WsEvent.FileContent(json.optString("path",""), json.optString("content","")))
                            
                            // 🚀 EKSİK OLAN KISIM BURASIYDI EKLENDİ!
                            "prompt_archives" -> {
                                val arr = json.getJSONArray("list")
                                val list = (0 until arr.length()).map { arr.getString(it) }
                                _events.emit(WsEvent.PromptArchives(list))
                            }
                "prompt_content" -> _events.emit(WsEvent.PromptContent(
                                json.getString("name"),
                                json.optString("content", ""),
                                json.optBoolean("is_default", true)
                            ))
                            
                            "version_info" -> {
                                val d = json.getJSONObject("data")
                                val cl = d.optJSONArray("changelog")
                                val changelog = if (cl != null) (0 until cl.length()).map { cl.getString(it) } else emptyList()
                                _events.emit(WsEvent.VersionInfo(
                                    d.optString("script_version","0"),
                                    d.optString("prompt_version","0"),
                                    json.optBoolean("has_update", false),
                                    changelog
                                ))
                            }
                            "export_done"  -> _events.emit(WsEvent.ExportDone(
                                json.optString("path",""),
                                json.optString("format","txt"),
                                json.optString("text","")))
                            "error"        -> _events.emit(WsEvent.Error(json.getString("text")))
                        }
                    } catch (_: Exception) {}
                }
            }
            override fun onFailure(ws: WebSocket, t: Throwable, r: Response?) {
                _connected.value = false
                scope.launch { _events.emit(WsEvent.Disconnected); delay(3000); connect() }
            }
            override fun onClosed(ws: WebSocket, code: Int, reason: String) {
                _connected.value = false
                scope.launch { _events.emit(WsEvent.Disconnected); delay(3000); connect() }
            }
        })
    }

    fun disconnect() { webSocket?.close(1000, null); _connected.value = false }
    private fun send(obj: JSONObject) { webSocket?.send(obj.toString()) }

    fun listProjects()                          = send(JSONObject().put("type","list_projects"))
    fun autofix(project: String)                = send(JSONObject().put("type","autofix").put("project",project))
    fun task(project: String, task: String)     = send(JSONObject().put("type","task").put("project",project).put("task",task))
    fun addAdmob(project: String, appId: String, unitId: String) = send(JSONObject().put("type","add_admob").put("project",project).put("app_id",appId).put("unit_id",unitId))
    fun checkNextTask(project: String)          = send(JSONObject().put("type","check_next_task").put("project",project))
    fun checkChainTask(project: String)         = send(JSONObject().put("type","check_chain_task").put("project",project))
    fun restoreAgentBackups()               = send(JSONObject().put("type","restore_agent_backups"))
    fun deleteChainTask()                       = send(JSONObject().put("type","delete_chain_task"))
    fun buildDebug(project: String)             = send(JSONObject().put("type","build_debug").put("project",project))
    fun cloneProject(oldName: String, newName: String) = send(JSONObject().put("type","clone_project").put("old_name",oldName).put("new_name",newName))
    fun saveLogo(project: String, base64Data: String)    = send(JSONObject().put("type","save_logo").put("project",project).put("data",base64Data))
    fun deleteProject(name: String)             = send(JSONObject().put("type","delete_project").put("project",name))
    fun buildRelease(project: String)           = send(JSONObject().put("type","build_release").put("project",project))
    fun killProcess()                           = send(JSONObject().put("type","kill_process"))
    fun checkUpdates()                          = send(JSONObject().put("type","check_updates"))
    fun deleteApk(path: String)                 = send(JSONObject().put("type","delete_apk").put("path",path))
    fun deleteAllApks()                         = send(JSONObject().put("type","delete_all_apks"))
    fun getVersion()                            = send(JSONObject().put("type","get_version"))
    fun setAutoMode(enabled: Boolean)           = send(JSONObject().put("type","set_auto_mode").put("enabled",enabled))
    fun sendInput(text: String)                 = send(JSONObject().put("type","send_input").put("text",text))
    fun newProject(name: String, task: String, pkg: String = "")  = send(JSONObject().put("type","new_project").put("name",name).put("task",task).put("pkg",pkg))
    fun listBackups(project: String = "")       = send(JSONObject().put("type","list_backups").put("project",project))
    fun backup(project: String, note: String = "yedek", backupType: String = "normal") = send(JSONObject().put("type","backup").put("project",project).put("note",note).put("backup_type",backupType))
    fun deleteBackup(name: String)             = send(JSONObject().put("type","delete_backup").put("name",name))
    fun restoreBackup(name: String)             = send(JSONObject().put("type","restore_backup").put("name",name))
    fun listKeystores()                         = send(JSONObject().put("type","list_keystores"))
    fun deleteKeystore(name: String)            = send(JSONObject().put("type","delete_keystore").put("name",name))
    fun listApis()                              = send(JSONObject().put("type","list_apis"))
    fun getProviders()                          = send(JSONObject().put("type","get_providers"))
    fun saveApi(name: String, key: String)      = send(JSONObject().put("type","save_api").put("name",name).put("key",key))
    fun listApks(project: String = "")          = send(JSONObject().put("type","list_apks").put("project",project))
    fun getSettings()                           = send(JSONObject().put("type","get_settings"))
    fun saveSettings(data: Map<String, String>) {
        val d = JSONObject()
        data.forEach { (k,v) -> d.put(k,v) }
        send(JSONObject().put("type","save_settings").put("data",d))
    }
    fun getProjectsConf()                       = send(JSONObject().put("type","get_projects_conf"))
    fun saveProjectsConf(content: String)       = send(JSONObject().put("type","save_projects_conf").put("content",content))
    fun exportSources(project: String, format: String = "txt") = send(
        JSONObject().put("type","export_sources").put("project",project).put("format",format))
    fun systemInfo()                            = send(JSONObject().put("type","system_info"))
    fun checkDeps()                             = send(JSONObject().put("type","check_deps"))
    fun getPrompt(name: String) = send(JSONObject().put("type","get_prompt").put("name",name))
    fun savePrompt(name: String, content: String) = send(JSONObject().put("type","save_prompt").put("name",name).put("content",content))
    fun listPromptArchives() = send(JSONObject().put("type","list_prompt_archives"))
    fun savePromptArchive(arcName: String, promptName: String, content: String) = send(
        JSONObject().put("type","save_prompt_archive")
            .put("arc_name",arcName).put("prompt_name",promptName).put("content",content))
    fun loadPromptArchive(arcFile: String) = send(
        JSONObject().put("type","load_prompt_archive").put("arc_file",arcFile))
    fun deletePromptArchive(arcFile: String) = send(
        JSONObject().put("type","delete_prompt_archive").put("arc_file",arcFile))
    fun resetPrompt(name: String) = send(JSONObject().put("type","reset_prompt").put("name",name))
}
