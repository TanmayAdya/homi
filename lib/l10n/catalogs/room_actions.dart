const roomActionTranslations = <String, Map<String, String>>{
  'No scan yet': {
    'es': 'Aún sin escaneo',
    'zh-Hans': '尚未扫描',
    'zh-Hant': '尚未掃描',
    'vi': 'Chưa quét',
    'fil': 'Wala pang scan',
  },
  'Photos & measurements': {
    'es': 'Fotos y medidas',
    'zh-Hans': '照片和测量',
    'zh-Hant': '照片和測量',
    'vi': 'Ảnh và số đo',
    'fil': 'Mga larawan at sukat',
  },
  'Scan saved': {
    'es': 'Escaneo guardado',
    'zh-Hans': '扫描已保存',
    'zh-Hant': '掃描已儲存',
    'vi': 'Đã lưu bản quét',
    'fil': 'Na-save ang scan',
  },
  'Review scan': {
    'es': 'Revisar escaneo',
    'zh-Hans': '检查扫描',
    'zh-Hant': '檢查掃描',
    'vi': 'Xem lại bản quét',
    'fil': 'Suriin ang scan',
  },
  'View model': {
    'es': 'Ver modelo',
    'zh-Hans': '查看模型',
    'zh-Hant': '檢視模型',
    'vi': 'Xem mô hình',
    'fil': 'Tingnan ang modelo',
  },
  'Open room': {
    'es': 'Abrir habitación',
    'zh-Hans': '打开房间',
    'zh-Hant': '開啟房間',
    'vi': 'Mở phòng',
    'fil': 'Buksan ang kuwarto',
  },
  'Saved place scans': {
    'es': 'Escaneos de lugares guardados',
    'zh-Hans': '已保存的区域扫描',
    'zh-Hant': '已儲存的區域掃描',
    'vi': 'Bản quét khu vực đã lưu',
    'fil': 'Mga na-save na scan ng lugar',
  },
  'View connected model': {
    'es': 'Ver modelo conectado',
    'zh-Hans': '查看相连模型',
    'zh-Hant': '檢視相連模型',
    'vi': 'Xem mô hình liên kết',
    'fil': 'Tingnan ang magkakaugnay na modelo',
  },
  'Scan connected rooms': {
    'es': 'Escanear habitaciones conectadas',
    'zh-Hans': '扫描相连房间',
    'zh-Hant': '掃描相連房間',
    'vi': 'Quét các phòng liền nhau',
    'fil': 'I-scan ang magkakaugnay na mga kuwarto',
  },
  "In connected model": {
    "es": "En el modelo conectado",
    "zh-Hans": "已包含在相连模型中",
    "zh-Hant": "已包含在相連模型中",
    "vi": "Có trong mô hình liên kết",
    "fil": "Kasama sa magkakaugnay na modelo",
  },
  "The previous scan was interrupted. Start a new scan when ready.": {
    "es": "El escaneo anterior se interrumpió. Inicie otro cuando esté listo.",
    "zh-Hans": "上次扫描中断。准备好后可开始新扫描。",
    "zh-Hant": "上次掃描中斷。準備好後可開始新掃描。",
    "vi": "Lần quét trước bị gián đoạn. Bắt đầu quét mới khi sẵn sàng.",
    "fil": "Naantala ang nakaraang scan. Magsimula ng bago kapag handa na.",
  },
  "Scan cancelled. Start a new scan when ready.": {
    "es": "Escaneo cancelado. Inicie otro cuando esté listo.",
    "zh-Hans": "扫描已取消。准备好后可开始新扫描。",
    "zh-Hant": "掃描已取消。準備好後可開始新掃描。",
    "vi": "Đã hủy quét. Bắt đầu quét mới khi sẵn sàng.",
    "fil": "Nakansela ang scan. Magsimula ng bago kapag handa na.",
  },
  "Scanning was interrupted. Start a new scan when ready.": {
    "es": "Se interrumpió el escaneo. Inicie otro cuando esté listo.",
    "zh-Hans": "扫描中断。准备好后可开始新扫描。",
    "zh-Hant": "掃描中斷。準備好後可開始新掃描。",
    "vi": "Quét bị gián đoạn. Bắt đầu quét mới khi sẵn sàng.",
    "fil": "Naantala ang pag-scan. Magsimula ng bago kapag handa na.",
  },
  "The scan could not be processed. Try again in good light, or use photos and manual measurements.": {
    "es":
        "No se pudo procesar el escaneo. Reintente con buena luz o use fotos y mediciones manuales.",
    "zh-Hans": "无法处理扫描。请在光线充足时重试，或使用照片和手动测量。",
    "zh-Hant": "無法處理掃描。請在光線充足時重試，或使用照片和手動測量。",
    "vi":
        "Không xử lý được bản quét. Thử lại nơi đủ sáng hoặc dùng ảnh và đo thủ công.",
    "fil":
        "Hindi maproseso ang scan. Subukang muli sa maliwanag na lugar o gumamit ng larawan at manwal na sukat.",
  },
  "Cancellation was requested. If the camera stays open, close the native scan. Its result will not be saved.": {
    "es":
        "Se solicitó cancelar. Si la cámara sigue abierta, cierre el escáner nativo. Su resultado no se guardará.",
    "zh-Hans": "已请求取消。如果相机仍然打开，请关闭原生扫描界面。其结果不会保存。",
    "zh-Hant": "已要求取消。如果相機仍開啟，請關閉原生掃描介面。其結果不會儲存。",
    "vi":
        "Đã yêu cầu hủy. Nếu máy ảnh vẫn mở, đóng màn hình quét gốc. Kết quả sẽ không được lưu.",
    "fil":
        "Hiniling ang pagkansela. Kung bukas pa ang camera, isara ang native scan. Hindi ise-save ang resulta.",
  },
  "The connected capture was interrupted. Start a new capture when ready.": {
    "es": "La captura conectada se interrumpió. Inicie otra cuando esté listo.",
    "zh-Hans": "相连扫描中断。准备好后可开始新扫描。",
    "zh-Hant": "相連掃描中斷。準備好後可開始新掃描。",
    "vi":
        "Quá trình quét liên kết bị gián đoạn. Bắt đầu quét mới khi sẵn sàng.",
    "fil":
        "Naantala ang konektadong pag-scan. Magsimula ng bago kapag handa na.",
  },
  "Continuous capture connects the rooms you choose in one tracking session. Android captures approximate surfaces and points, not identified fixtures. Existing independent scans use reviewed alignment below.": {
    "es":
        "La captura continua conecta las habitaciones que elija en una sesión. Android captura superficies y puntos aproximados, sin identificar accesorios. Para escaneos independientes use la alineación revisada de abajo.",
    "zh-Hans": "连续扫描在一次跟踪中连接您选择的房间。Android 捕获近似表面和点，不识别设施。已有的独立扫描可在下方检查对齐。",
    "zh-Hant": "連續掃描在一次追蹤中連接您選擇的房間。Android 擷取近似表面和點，不辨識設備。現有獨立掃描可在下方檢查對齊。",
    "vi":
        "Quét liên tục kết nối các phòng bạn chọn trong một phiên theo dõi. Android ghi nhận bề mặt và điểm gần đúng, không nhận dạng thiết bị. Các bản quét riêng dùng căn chỉnh có xem xét bên dưới.",
    "fil":
        "Pinag-uugnay ng tuloy-tuloy na pag-scan ang mga kuwartong pipiliin sa iisang session. Tinatayang surface at mga punto ang kinukuha ng Android, hindi kinikilalang fixture. Gamitin ang sinusuring pag-align sa ibaba para sa dating hiwalay na scan.",
  },
  "This model step could not finish. Try again when ready.": {
    "es":
        "No se pudo completar este paso del modelo. Reintente cuando esté listo.",
    "zh-Hans": "此模型步骤未能完成。准备好后请重试。",
    "zh-Hant": "此模型步驟未能完成。準備好後請重試。",
    "vi": "Không hoàn tất được bước mô hình này. Thử lại khi sẵn sàng.",
    "fil":
        "Hindi natapos ang hakbang na ito sa modelo. Subukang muli kapag handa na.",
  },
  "The home model could not be opened. Try again.": {
    "es": "No se pudo abrir el modelo de la vivienda. Inténtelo de nuevo.",
    "zh-Hans": "无法打开房屋模型。请重试。",
    "zh-Hant": "無法開啟房屋模型。請重試。",
    "vi": "Không mở được mô hình ngôi nhà. Vui lòng thử lại.",
    "fil": "Hindi mabuksan ang modelo ng bahay. Subukang muli.",
  },
};
