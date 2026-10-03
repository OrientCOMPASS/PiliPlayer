package com.example.piliplus

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings

/**
 * SAF(Storage Access Framework) 目录浏览桥 —— 第十九轮「本机文件目录浏览重写」。
 *
 * 为什么要有它: 安卓 11+ 的作用域存储下, 应用只有 READ_MEDIA_VIDEO/READ_MEDIA_IMAGES,
 * FUSE 会**只让应用看到媒体文件**: 目录里的其它文件直接消失, 只含非媒体文件的目录
 * 甚至列不出来(真机反馈「文件管理器里有, 应用里浏览不到 / 目录显示不全」)。
 * 用户通过系统「选择文件夹」授权一个目录树后, 走 DocumentsContract 列目录能看到
 * 该树下的**全部**条目(与系统文件管理器一致), 授权还能持久化(重启不丢)。
 *
 * 约定:
 *  * treeUri  —— `content://com.android.externalstorage.documents/tree/primary%3ADownload`
 *  * docId    —— 树内文档 id, 例如 `primary:Download/电影`; 空串/null = 树根
 *  * 每个条目回给 Dart: name / docId / uri(可直接开 fd) / dir / size / mtime
 *
 * 播放不走这里: Dart 侧用 MainActivity 已有的 `resolveContentMedia` 把条目 uri
 * 导出成 fd, 以 `fd://N` 交给定制 libmpv(与「系统分享打开视频」同一条路)。
 *
 * 所有 ContentResolver 查询都在调用方给的后台线程里跑(见 MainActivity),
 * 只有 MethodChannel.Result 回到主线程。
 */
object SafBrowser {

    class SafException(message: String) : Exception(message)

    /** 是否支持 SAF(安卓 5.0+; 本工程 minSdk 早已高于它, 留个兜底判断) */
    fun isSupported(): Boolean = Build.VERSION.SDK_INT >= 21

    fun isTreeUri(uri: Uri): Boolean = try {
        DocumentsContract.isTreeUri(uri)
    } catch (e: Throwable) {
        // 个别 ROM 对畸形 uri 会抛异常; 用路径特征兜底判断
        uri.pathSegments.contains("tree")
    }

    /** 树根 docId(拿不到就抛 SafException, 让 Dart 侧展示原因) */
    fun treeRootId(treeUri: Uri): String = try {
        DocumentsContract.getTreeDocumentId(treeUri)
    } catch (e: Throwable) {
        throw SafException("无法解析目录树: ${e.message ?: e.javaClass.simpleName}")
    }

    /** 目录树摘要: uri / docId / name(显示名) */
    fun describeTree(resolver: ContentResolver, treeUri: Uri): Map<String, Any?>? {
        val rootId = try {
            treeRootId(treeUri)
        } catch (e: Throwable) {
            return null
        }
        val docUri = try {
            DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
        } catch (e: Throwable) {
            return null
        }
        val display = queryDisplayName(resolver, docUri)
        return mapOf(
            "uri" to treeUri.toString(),
            "docId" to rootId,
            "name" to (display?.takeIf { it.isNotEmpty() } ?: fallbackName(rootId)),
        )
    }

    /** 已持久化授权的目录树(重启后依然在, 这就是「本机存储」的入口列表) */
    fun persistedTrees(resolver: ContentResolver): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val permissions = try {
            resolver.persistedUriPermissions
        } catch (e: Throwable) {
            return out
        }
        for (p in permissions) {
            if (!p.isReadPermission) continue
            val uri = p.uri ?: continue
            if (!isTreeUri(uri)) continue
            describeTree(resolver, uri)?.let { out.add(it) }
        }
        return out
    }

    /** 释放一个目录树的持久化授权(用户在快捷方式里删除时调用) */
    fun releaseTree(resolver: ContentResolver, treeUri: Uri): Boolean = try {
        resolver.releasePersistableUriPermission(
            treeUri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )
        true
    } catch (e: Throwable) {
        try {
            resolver.releasePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            true
        } catch (e2: Throwable) {
            false
        }
    }

    /** 记下(并返回)刚授权的目录树; 授权失败时抛 SafException */
    fun persistTree(resolver: ContentResolver, treeUri: Uri): Map<String, Any?> {
        try {
            resolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (e: Throwable) {
            throw SafException("保存目录授权失败: ${e.message ?: e.javaClass.simpleName}")
        }
        return describeTree(resolver, treeUri)
            ?: throw SafException("无法读取所选目录: $treeUri")
    }

    /**
     * 列目录。单个条目取不到属性不会让整次列举失败(「显示不全」的教训);
     * 整层查询失败才抛 SafException。
     */
    fun listChildren(
        resolver: ContentResolver,
        treeUri: Uri,
        docId: String?
    ): List<Map<String, Any?>> {
        val parentId = if (docId.isNullOrEmpty()) treeRootId(treeUri) else docId
        val childrenUri = try {
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        } catch (e: Throwable) {
            throw SafException("目录地址无效: ${e.message ?: e.javaClass.simpleName}")
        }
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )
        val out = ArrayList<Map<String, Any?>>()
        var cursor: Cursor? = null
        try {
            cursor = resolver.query(childrenUri, projection, null, null, null)
            if (cursor == null) {
                throw SafException("系统没有返回目录内容(可能授权已失效, 请重新选择文件夹)")
            }
            val iId = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val iName = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val iMime = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val iSize = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val iMtime = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                try {
                    val id = if (iId >= 0) cursor.getString(iId) else null
                    val name = if (iName >= 0) cursor.getString(iName) else null
                    if (id.isNullOrEmpty() || name.isNullOrEmpty()) continue
                    val mime = if (iMime >= 0) cursor.getString(iMime) else null
                    val isDir = DocumentsContract.Document.MIME_TYPE_DIR == mime
                    val size: Long? = if (!isDir && iSize >= 0 && !cursor.isNull(iSize)) {
                        cursor.getLong(iSize)
                    } else {
                        null
                    }
                    val mtime: Long? = if (iMtime >= 0 && !cursor.isNull(iMtime)) {
                        cursor.getLong(iMtime)
                    } else {
                        null
                    }
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                    val entry = HashMap<String, Any?>(6)
                    entry["name"] = name
                    entry["docId"] = id
                    entry["uri"] = docUri.toString()
                    entry["dir"] = isDir
                    if (size != null) entry["size"] = size
                    if (mtime != null) entry["mtime"] = mtime
                    out.add(entry)
                } catch (e: Throwable) {
                    // 单条目异常(虚拟文档/权限位)跳过, 不影响同层其它条目
                    continue
                }
            }
        } catch (e: SafException) {
            throw e
        } catch (e: SecurityException) {
            throw SafException("没有该目录的读取授权, 请重新选择文件夹")
        } catch (e: Throwable) {
            throw SafException("读取目录失败: ${e.message ?: e.javaClass.simpleName}")
        } finally {
            try {
                cursor?.close()
            } catch (e: Throwable) {
            }
        }
        return out
    }

    private fun queryDisplayName(resolver: ContentResolver, docUri: Uri): String? {
        var cursor: Cursor? = null
        return try {
            cursor = resolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null, null, null
            )
            if (cursor != null && cursor.moveToFirst()) cursor.getString(0) else null
        } catch (e: Throwable) {
            null
        } finally {
            try {
                cursor?.close()
            } catch (e: Throwable) {
            }
        }
    }

    /** docId 兜底显示名: `primary:Download/电影` -> `电影`, `primary:` -> `内部存储` */
    fun fallbackName(docId: String): String {
        val tail = docId.substringAfterLast('/', docId).substringAfterLast(':', docId)
        if (tail.isNotEmpty()) return tail
        val volume = docId.substringBefore(':', docId)
        return if (volume == "primary") "内部存储" else volume.ifEmpty { "本机目录" }
    }

    /** docId 的人类可读路径: `primary:Download/电影` -> `内部存储/Download/电影` */
    fun readablePath(docId: String): String {
        val volume = docId.substringBefore(':', "")
        val rest = docId.substringAfter(':', "")
        val head = when (volume) {
            "primary" -> "内部存储"
            "" -> "本机"
            else -> volume
        }
        return if (rest.isEmpty()) head else "$head/$rest"
    }

    /** 系统「所有文件访问权限」(MANAGE_EXTERNAL_STORAGE, 安卓 11+) */
    fun hasAllFilesAccess(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
        try {
            Environment.isExternalStorageManager()
        } catch (e: Throwable) {
            false
        }

    /** 打开「所有文件访问权限」设置页; 失败时退回应用详情页 */
    fun openAllFilesAccessSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val pkg = context.packageName
        val intents = listOf(
            Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$pkg")),
            Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
        )
        for (intent in intents) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                return true
            } catch (e: Throwable) {
                continue
            }
        }
        return false
    }
}
