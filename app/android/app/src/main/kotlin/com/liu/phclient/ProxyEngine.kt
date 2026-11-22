package com.liu.phclient

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import java.io.File
import java.util.concurrent.Executors

/**
 * In-app proxy engine (v0.2.5): runs sing-box (libbox) in local-proxy mode.
 *
 * No VpnService, no system VPN permission, no conflict with the user's
 * Shadiao VPN (which may run at the same time). sing-box listens on a
 * mixed (HTTP + SOCKS5) inbound on 127.0.0.1 and forwards to the user's
 * own node (VLESS / VMess / SOCKS5 / HTTP). The app's own traffic —
 * Dart HttpClient via findProxy, thumbnails, and ExoPlayer via the Dart
 * loopback relay — goes through 127.0.0.1.
 *
 * Two slots: the main service and a throwaway test service on a different
 * mixed port, used for per-node latency tests so testing never disturbs
 * the active proxy. Same pattern as shadiao's UrlTestManager, which runs
 * a second CommandServer concurrently.
 *
 * All libbox calls run on a single background thread; MethodChannel
 * results are answered from that thread (safe in the v2 embedding).
 */
object ProxyEngine {
    private const val TAG = "ProxyEngine"

    /** Mixed inbound port for the main service (Dart clients use this). */
    const val MAIN_PORT = 10808

    /** Mixed inbound port for the throwaway latency-test service. */
    const val TEST_PORT = 10809

    private val executor = Executors.newSingleThreadExecutor()

    @Volatile
    private var setupDone = false

    @Volatile
    private var mainServer: CommandServer? = null

    @Volatile
    private var testServer: CommandServer? = null

    fun isRunning(): Boolean = mainServer != null

    private val handler = object : CommandServerHandler {
        override fun serviceStop() {
            Log.d(TAG, "serviceStop requested")
        }

        override fun serviceReload() {
            Log.d(TAG, "serviceReload requested")
        }

        override fun getSystemProxyStatus(): SystemProxyStatus {
            return SystemProxyStatus()
        }

        override fun setSystemProxyEnabled(enabled: Boolean) {
            // Android has no system proxy setting; nothing to do.
        }

        override fun writeDebugMessage(message: String?) {
            Log.d(TAG, "libbox: $message")
        }
    }

    private fun ensureSetup(context: Context) {
        if (setupDone) return
        synchronized(this) {
            if (setupDone) return
            val workDir = File(context.filesDir, "sing-box")
            if (!workDir.exists()) workDir.mkdirs()
            val options = io.nekohasekai.libbox.SetupOptions().apply {
                basePath = workDir.absolutePath
                workingPath = workDir.absolutePath
                tempPath = context.cacheDir.absolutePath
            }
            Libbox.setup(options)
            setupDone = true
        }
    }

    private fun startServer(
        context: Context,
        config: String,
        slot: Int,
    ) {
        ensureSetup(context)
        if (slot == 0) {
            if (mainServer == null) {
                val server = Libbox.newCommandServer(
                    handler,
                    ProxyPlatformInterface(context.applicationContext),
                )
                server.start()
                mainServer = server
            }
            mainServer!!.startOrReloadService(
                config,
                io.nekohasekai.libbox.OverrideOptions(),
            )
        } else {
            if (testServer == null) {
                val server = Libbox.newCommandServer(
                    handler,
                    ProxyPlatformInterface(context.applicationContext),
                )
                server.start()
                testServer = server
            }
            testServer!!.startOrReloadService(
                config,
                io.nekohasekai.libbox.OverrideOptions(),
            )
        }
    }

    private fun stopServer(slot: Int) {
        val server = if (slot == 0) mainServer else testServer
        if (server == null) return
        try {
            server.closeService()
        } catch (e: Exception) {
            Log.e(TAG, "closeService failed", e)
        }
        try {
            server.close()
        } catch (e: Exception) {
            Log.e(TAG, "close failed", e)
        }
        if (slot == 0) mainServer = null else testServer = null
    }

    /** Start (or reload) the main proxy service with [config] JSON. */
    fun start(context: Context, config: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                startServer(context, config, 0)
                result.success("ok")
            } catch (e: Exception) {
                Log.e(TAG, "start failed", e)
                result.error("START_FAILED", e.message ?: e.toString(), null)
            }
        }
    }

    /** Stop the main proxy service. */
    fun stop(result: MethodChannel.Result) {
        executor.execute {
            try {
                stopServer(0)
                result.success("ok")
            } catch (e: Exception) {
                Log.e(TAG, "stop failed", e)
                result.error("STOP_FAILED", e.message ?: e.toString(), null)
            }
        }
    }

    /** Start (or reload) the throwaway latency-test service. */
    fun startTest(context: Context, config: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                startServer(context, config, 1)
                result.success("ok")
            } catch (e: Exception) {
                Log.e(TAG, "startTest failed", e)
                result.error("START_FAILED", e.message ?: e.toString(), null)
            }
        }
    }

    /** Stop the throwaway latency-test service. */
    fun stopTest(result: MethodChannel.Result) {
        executor.execute {
            try {
                stopServer(1)
                result.success("ok")
            } catch (e: Exception) {
                Log.e(TAG, "stopTest failed", e)
                result.error("STOP_FAILED", e.message ?: e.toString(), null)
            }
        }
    }
}

/**
 * Minimal PlatformInterface for headless (no-TUN) mode, copied from the
 * proven shadiao HeadlessPlatformInterface: no TUN support, no interface
 * monitoring beyond reporting the current default interface. sing-box
 * never calls openTun here because the config has no tun inbound.
 */
private class ProxyPlatformInterface(
    private val context: Context,
) : PlatformInterface {

    companion object {
        private const val TAG = "ProxyPlatform"
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = false

    override fun autoDetectInterfaceControl(fd: Int) {
        // Never called (usePlatformAutoDetectInterfaceControl is false).
    }

    override fun openTun(options: TunOptions?): Int {
        throw UnsupportedOperationException("Headless mode does not support TUN")
    }

    override fun useProcFS(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    }

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String?,
        sourcePort: Int,
        destinationAddress: String?,
        destinationPort: Int,
    ): io.nekohasekai.libbox.ConnectionOwner {
        return io.nekohasekai.libbox.ConnectionOwner()
    }

    override fun clearDNSCache() {}

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        try {
            val cm = context.getSystemService(
                Context.CONNECTIVITY_SERVICE,
            ) as ConnectivityManager
            val activeNetwork = cm.activeNetwork
            if (activeNetwork != null) {
                val linkProperties = cm.getLinkProperties(activeNetwork)
                val interfaceName = linkProperties?.interfaceName
                if (interfaceName != null) {
                    val netIf = java.net.NetworkInterface.getByName(interfaceName)
                    val index = netIf?.index ?: 0
                    listener?.updateDefaultInterface(interfaceName, index, false, false)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to detect default interface", e)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        return object : NetworkInterfaceIterator {
            override fun hasNext(): Boolean = false
            override fun next(): io.nekohasekai.libbox.NetworkInterface =
                throw NoSuchElementException()
        }
    }

    override fun sendNotification(notification: io.nekohasekai.libbox.Notification?) {}

    override fun readWIFIState(): io.nekohasekai.libbox.WIFIState? = null

    override fun includeAllNetworks(): Boolean = false

    override fun localDNSTransport(): io.nekohasekai.libbox.LocalDNSTransport? = null

    override fun systemCertificates(): StringIterator? = null

    override fun underNetworkExtension(): Boolean = false
}
