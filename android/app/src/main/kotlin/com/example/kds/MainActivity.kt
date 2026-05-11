package com.example.kds // 본인의 패키지명 유지

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import com.bixolon.commonlib.connectivity.NetworkService // 라이브러리 임포트
import java.lang.Exception
import android.util.Log
import android.view.KeyEvent

class MainActivity: FlutterActivity() {
    companion object {
        init {
            try {
                // 'libbxl_common.so'에서 'lib'과 '.so'를 뺀 이름만 적습니다.
                System.loadLibrary("bxl_common")
                Log.d("KDS_DEBUG", "✅ 엔진 파일(bxl_common) 로드 성공!")
            } catch (e: UnsatisfiedLinkError) {
                Log.e("KDS_DEBUG", "❌ 엔진 파일 로드 실패: ${e.message}")
            }
        }
    }
    private val SENSOR_CHANNEL = "com.sg.kds/printer_status"
    private val ACTION_CHANNEL = "com.sg.kds/printer_action"
    private val SCANNER_CHANNEL = "com.sg.kds/scanner"
    private var scannerChannel: MethodChannel? = null
    private var barcodeBuffer = StringBuilder()
    private var lastKeyTime: Long = 0
    private var statusSink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())

    // 빅솔론 네트워크 서비스 변수
    private var networkService: NetworkService? = null
    private var isMonitoring = false
    private val printerIp = "192.168.10.130" // 👈 나중에 실제 프린터 IP로 수정하세요!
    private var lastStatus: String? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d("KDS_DEBUG", "🚀 채널 설정 완료!")

        scannerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCANNER_CHANNEL)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SENSOR_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Log.d("KDS_DEBUG", "📢 Flutter에서 신호 감지 시작!")
                    statusSink = events
                    startMonitoring()
                }

                override fun onCancel(arguments: Any?) {
                    stopMonitoring()
                    statusSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ACTION_CHANNEL).setMethodCallHandler { call, result ->
//            if (call.method == "printTestLabel") {
//                val isSuccess = sendTestPrint() // 인쇄 함수 실행
//                if (isSuccess) result.success(true) else result.error("ERROR", "인쇄 실패", null)
//            } else {
//                result.notImplemented()
//            }
            when (call.method) {
                "printTestLabel" -> {
                    val menus = call.arguments as? List<String> // 🚀 Flutter에서 보낸 메뉴 리스트 수신
                    val startTime = System.currentTimeMillis()

                    val isSuccess = if (menus != null) sendTestPrint(menus) else false

                    if (isSuccess) {
                        Log.d("KDS_SPEED", "⏱️ [텍스트] 전송 완료: ${System.currentTimeMillis() - startTime}ms")
                        result.success(true)
                    } else result.error("ERROR", "인쇄 실패", null)
                }

                "printImageLabel" -> {
                    // Flutter에서 보낸 이미지 데이터(Uint8List -> ByteArray) 수신
                    val imageBytes = call.arguments as? ByteArray
                    if (imageBytes == null) {
                        result.error("ARG_ERR", "이미지 데이터가 없습니다.", null)
                        return@setMethodCallHandler
                    }

                    val startTime = System.currentTimeMillis()
                    Log.d("KDS_SPEED", "⏱️ [이미지] 출력 시작 (데이터 크기: ${imageBytes.size} bytes)")

                    val isSuccess = sendImagePrint(imageBytes)

                    if (isSuccess) {
                        Log.d("KDS_SPEED", "⏱️ [이미지] 데이터 전송 완료: ${System.currentTimeMillis() - startTime}ms")
                        result.success(true)
                    } else result.error("ERROR", "이미지 인쇄 실패", null)
                }
                "checkHardware" -> {
                    checkPrinterHardware()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private val clearBufferRunnable = Runnable {
        if (barcodeBuffer.isNotEmpty()) {
            Log.w("KDS_DEBUG", "⚠️ 1.5초간 입력이 없어 버퍼 초기화됨 (버려진 데이터: $barcodeBuffer)")
            barcodeBuffer.clear()
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {

            // 🚀 1. 키가 하나라도 들어오면, 예약되어 있던 '버퍼 지우기' 타이머를 즉시 취소합니다.
            handler.removeCallbacks(clearBufferRunnable)

            val keyCode = event.keyCode
            // 엔터키(스캔 완료) 처리
            if (keyCode == KeyEvent.KEYCODE_ENTER || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER) {
                if (barcodeBuffer.isNotEmpty()) {
                    val finalBarcode = barcodeBuffer.toString().trim()
                    barcodeBuffer.clear()
                    Log.d("KDS_DEBUG", "🎯 [Native Scanner] 스캔 완료: $finalBarcode")

                    handler.post {
                        scannerChannel?.invokeMethod("onScan", finalBarcode)
                    }
                }
                return true
            } else {
                val unicodeChar = event.unicodeChar
                if (unicodeChar >= 32) {
                    barcodeBuffer.append(unicodeChar.toChar())
                }

                // 🚀 2. 글자를 버퍼에 넣은 후, "1.5초(1500ms) 동안 아무 입력이 없으면 버퍼를 비워라"고 새로 타이머를 맞춥니다.
                handler.postDelayed(clearBufferRunnable, 1500)

                if (unicodeChar > 0) return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun sendImagePrint(imageBytes: ByteArray): Boolean {
        if (networkService == null || !isMonitoring) return false

        return try {
            Thread {
                val combined = mutableListOf<Byte>()

                // 1. 초기화
                combined.addAll(byteArrayOf(0x1B, 0x40).toList())

                // 2. 인쇄 영역 너비 설정 (384 dots)
                combined.addAll(byteArrayOf(0x1D, 0x57, 0x80.toByte(), 0x01.toByte()).toList())

                // 🚀 3. 왼쪽 정렬 (이미지 내부 정렬)
                // 기존 0x01(중앙) -> 0x00(왼쪽)으로 변경하여 딱 붙게 만듭니다.
                combined.addAll(byteArrayOf(0x1B, 0x61, 0x00).toList())

                // 🚀 4. 왼쪽 마진 설정 (GS L) - 여백 제거
                // 기존 40이었던 offsetDots를 0으로 변경하여 물리적 여백을 없앱니다.
                val offsetDots = 0
                val nL = (offsetDots % 256).toByte()
                val nH = (offsetDots / 256).toByte()
                combined.addAll(byteArrayOf(0x1D, 0x4C, nL, nH).toList())

                // 5. 이미지 데이터 추가
                combined.addAll(imageBytes.toList())

                // 6. 피딩 및 커팅
//                combined.addAll(byteArrayOf(0x1B, 0x64, 0x01).toList())
//                combined.addAll(byteArrayOf(0x1D, 0x56, 0x42, 0x00).toList())
                val feedLines: Byte = 0x04 // 👈 이 숫자로 하단 여백을 mm 단위로 미세 조절합니다.
                combined.addAll(byteArrayOf(0x1B, 0x64, feedLines).toList())

                // 🎯 변경 2: 종이를 더 빼지 말고 그 자리에서 즉시 커팅 (0x01)
                combined.addAll(byteArrayOf(0x1D, 0x56, 0x01).toList())

                networkService?.write(combined.toByteArray())
            }.start()
            true
        } catch (e: Exception) {
            Log.e("KDS_DEBUG", "❌ 이미지 전송 오류: ${e.message}")
            false
        }
    }

    private fun sendTestPrint(menus: List<String>): Boolean {
        if (networkService == null || !isMonitoring) return false

        return try {
            Thread {
                val output = mutableListOf<Byte>()
                // 한글 인코딩 설정
                val charset = java.nio.charset.Charset.forName("KSC5601")
                val orderNo = "105"

                // --- 1. 초기화 및 한글 모드 설정 ---
                output.addAll(byteArrayOf(0x1B, 0x40).toList()) // 초기화
                output.addAll(byteArrayOf(0x1C, 0x26).toList()) // 한글 모드 ON

                // --- 2. QR 코드 (중앙 정렬) ---
                output.addAll(byteArrayOf(0x1B, 0x61, 0x01).toList()) // 중앙 정렬
                output.addAll(byteArrayOf(0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x08).toList()) // 사이즈 8
                val dataLen = orderNo.length + 3
                output.addAll(byteArrayOf(0x1D, 0x28, 0x6B, dataLen.toByte(), 0x00, 0x31, 0x50, 0x30).toList())
                output.addAll(orderNo.toByteArray().toList())
                output.addAll(byteArrayOf(0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30).toList())
                output.addAll("\n".toByteArray().toList()) // QR 아래 여백

                // --- 3. 주문 번호: No. 105 (강조 및 확대) ---
                output.addAll(byteArrayOf(0x1B, 0x45, 0x01).toList()) // 강조(Bold) ON
                output.addAll(byteArrayOf(0x1D, 0x21, 0x22).toList()) // 가로세로 3배 확대
                output.addAll("No. $orderNo\n\n".toByteArray(charset).toList())

                output.addAll(byteArrayOf(0x1B, 0x45, 0x00).toList()) // 강조 OFF
                output.addAll(byteArrayOf(0x1D, 0x21, 0x00).toList()) // 일반 크기 복구

                // --- 4. 메뉴 리스트 (왼쪽 정렬) ---
                output.addAll(byteArrayOf(0x1B, 0x61, 0x00).toList()) // 왼쪽 정렬

                for (menu in menus) {
                    val lineOutput = mutableListOf<Byte>()
                    // 🚀 가운뎃점(•) 바이트 직접 삽입 (EUC-KR 0xB7)
                    lineOutput.addAll("    $menu\n".toByteArray(charset).toList())
                    output.addAll(lineOutput)
                }

                // --- 5. 용지 배출 및 커팅 ---
                output.addAll(byteArrayOf(0x1B, 0x64, 0x08).toList()) // 여백 충분히 주기
                output.addAll(byteArrayOf(0x1D, 0x56, 0x42, 0x00).toList()) // 커팅

                networkService?.write(output.toByteArray())
            }.start()
            true
        } catch (e: Exception) { false }
    }

    private fun checkPrinterHardware() {
        if (networkService == null || !isMonitoring) {
            Log.e("PRINTER_INFO", "❌ 프린터가 연결되어 있지 않습니다.")
            return
        }

        Thread {
            try {
                Log.d("PRINTER_INFO", "🔍 하드웨어 정보 요청 중...")

                // 🚀 [매뉴얼 3번] n = 2 (다중 바이트 지원 여부 확인)
                // 명령어: GS I 2 (1D 49 02)
                networkService?.write(byteArrayOf(0x1D, 0x49, 0x02))
                Thread.sleep(200) // 프린터 응답 대기
                val res2 = networkService?.read(500)
                Log.d("PRINTER_INFO", "📊 Multi-byte Support (n=2): ${res2?.contentToString()}")

                // 🚀 [매뉴얼 3번] n = 69 (현재 폰트 언어/코드 페이지 확인)
                // 명령어: GS I 69 (1D 49 45)
                networkService?.write(byteArrayOf(0x1D, 0x49, 0x45))
                Thread.sleep(200)
                val res69 = networkService?.read(500)
                Log.d("PRINTER_INFO", "📊 Current Language (n=69): ${res69?.contentToString()}")

            } catch (e: Exception) {
                Log.e("PRINTER_INFO", "❌ 정보 요청 중 에러: ${e.message}")
            }
        }.start()
    }

    private fun startMonitoring() {
        Log.d("KDS_DEBUG", "🔗 프린터 연결 시도 중... IP: $printerIp")
        if (isMonitoring) return
        isMonitoring = true

        // 안드로이드에서 네트워크 작업은 반드시 별도 Thread에서 해야 합니다.
        Thread {
            try {
                if (networkService == null) {
                    networkService = NetworkService(context)
                }

                // 9100 포트로 연결 시도 (timeout 3000ms)
                val result = networkService?.connect(printerIp, 9100, 3000, false)
                Log.d("KDS_DEBUG", "📡 연결 결과 코드: $result")

                if (result == 0) { // 연결 성공
                    checkPrinterStatusLoop()
                } else {
                    handler.post { statusSink?.error("CONN_FAIL", "프린터 연결 실패", null) }
                    isMonitoring = false
                }
            } catch (e: Exception) {
                e.printStackTrace()
                isMonitoring = false
            }
        }.start()
    }

    private fun stopMonitoring() {
        isMonitoring = false
        Thread {
            networkService?.disconnect()
        }.start()
    }

    private fun checkPrinterStatusLoop() {
        if (!isMonitoring) return

        // 레거시 코드에서 찾은 ASB(Automatic Status Back) 요청 바이트
        val asbr = byteArrayOf(0x08.toByte(), 0x1c.toByte(), 0x1d.toByte(), 0x61.toByte(), 0xff.toByte())

        try {
            // 프린터에 상태 확인 신호 전송
            networkService?.write(asbr)

            // 프린터의 응답 읽기 (최대 200ms 대기)
            val response = networkService?.read(200)

            if (response != null && response.size >= 3) {
                // 레거시 분석 결과: 3번째 바이트(index 2)의 0x80 비트가 종이 유무
                // 0x80(128)이면 종이 있음, 아니면 종이 없음(떼어짐)
                val isPaperPresent = (response[2].toInt() and 0x80) == 0x80
                val currentStatus = if (isPaperPresent) "ATTACHED" else "DETACHED"

                // 🚀 핵심: 이전 상태와 다를 때만 로그를 찍고 Flutter로 보냅니다.
                if (currentStatus != lastStatus) {
                    lastStatus = currentStatus
                    handler.post {
                        Log.d("KDS_DEBUG", "🔔 상태 변경 감지: $currentStatus")
                        statusSink?.success(currentStatus)
                    }
                }
            }
        } catch (e: Exception) {
            // 통신 에러 발생 시 처리
        }

        // 500ms 뒤에 다시 체크 (무한 루프)
        handler.postDelayed({ checkPrinterStatusLoop() }, 500)
    }
}