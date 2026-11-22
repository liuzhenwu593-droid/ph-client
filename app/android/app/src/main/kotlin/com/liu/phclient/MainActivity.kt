package com.liu.phclient

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.liu.phclient/proxy",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrBlank()) {
                        result.error("BAD_ARGS", "config is empty", null)
                    } else {
                        ProxyEngine.start(applicationContext, config, result)
                    }
                }
                "stop" -> ProxyEngine.stop(result)
                "startTest" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrBlank()) {
                        result.error("BAD_ARGS", "config is empty", null)
                    } else {
                        ProxyEngine.startTest(applicationContext, config, result)
                    }
                }
                "stopTest" -> ProxyEngine.stopTest(result)
                "isRunning" -> result.success(ProxyEngine.isRunning())
                else -> result.notImplemented()
            }
        }
    }
}
