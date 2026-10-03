package network.sov.node

import android.content.Context
import android.telephony.TelephonyManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class SimInfoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context

  override fun onAttachedToEngine(
      binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(
        binding.binaryMessenger, "network.sov.node/sim")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(
      call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "getMcc" -> {
        try {
          val tm = context.getSystemService(
              Context.TELEPHONY_SERVICE) as TelephonyManager
          val networkOp = tm.networkOperator
          if (!networkOp.isNullOrEmpty() &&
              networkOp.length >= 3) {
            result.success(networkOp.substring(0, 3))
            return
          }
          val simOp = tm.simOperator
          if (!simOp.isNullOrEmpty() && simOp.length >= 3) {
            result.success(simOp.substring(0, 3))
            return
          }
          result.success(null)
        } catch (e: Exception) {
          result.success(null)
        }
      }
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(
      binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
