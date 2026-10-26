import 'whole_home.dart';
import 'android_features.dart';

const nativeScanTranslations = <String, Map<String, String>>{
  ...wholeHomeNativeTranslations,
  ...androidFeatureNativeTranslations,
  "Scan this room": {
    "es": "Escanee esta habitación",
    "zh-Hans": "扫描此房间",
    "zh-Hant": "掃描此房間",
    "vi": "Quét phòng này",
    "fil": "I-scan ang kuwartong ito",
  },
  "Move slowly and follow the camera guidance. Stay on a safe, clear path. Scan only this room.": {
    "es":
        "Muévase despacio y siga las indicaciones de la cámara. Permanezca en un camino seguro y despejado. Escanee solo esta habitación.",
    "zh-Hans": "缓慢移动并遵循相机指引。保持在安全、畅通的路径上。仅扫描此房间。",
    "zh-Hant": "緩慢移動並遵循相機指引。保持在安全、暢通的路徑上。僅掃描此房間。",
    "vi":
        "Di chuyển chậm và làm theo hướng dẫn camera. Đi trên lối an toàn, thông thoáng. Chỉ quét phòng này.",
    "fil":
        "Dahan-dahang gumalaw at sundin ang gabay ng camera. Manatili sa ligtas at maluwag na daanan. I-scan lamang ang kuwartong ito.",
  },
  "Start room scan": {
    "es": "Iniciar escaneo de habitación",
    "zh-Hans": "开始房间扫描",
    "zh-Hant": "開始房間掃描",
    "vi": "Bắt đầu quét phòng",
    "fil": "Simulan ang pag-scan ng kuwarto",
  },
  "Live room camera view. Detected surfaces and sampled points are outlined.": {
    "es":
        "Vista de cámara de la habitación en vivo. Se resaltan las superficies detectadas y los puntos muestreados.",
    "zh-Hans": "房间实时相机视图。已标出检测到的表面和采样点。",
    "zh-Hant": "房間即時相機檢視。已標出偵測到的表面和取樣點。",
    "vi":
        "Hình ảnh phòng trực tiếp từ camera. Các bề mặt và điểm lấy mẫu được đánh dấu.",
    "fil":
        "Live na camera ng kuwarto. May balangkas ang mga natukoy na ibabaw at sample na punto.",
  },
  "Room scan": {
    "es": "Escaneo de habitación",
    "zh-Hans": "房间扫描",
    "zh-Hant": "房間掃描",
    "vi": "Quét phòng",
    "fil": "Pag-scan ng kuwarto",
  },
  "Finding position. Move slowly while facing the room.": {
    "es": "Buscando posición. Muévase despacio mirando hacia la habitación.",
    "zh-Hans": "正在定位。请面向房间缓慢移动。",
    "zh-Hant": "正在定位。請面向房間緩慢移動。",
    "vi": "Đang xác định vị trí. Di chuyển chậm và hướng vào phòng.",
    "fil":
        "Hinahanap ang posisyon. Dahan-dahang gumalaw habang nakaharap sa kuwarto.",
  },

  "Camera-only scan": {
    "es": "Escaneo solo con cámara",
    "zh-Hans": "仅相机扫描",
    "zh-Hant": "僅相機掃描",
    "vi": "Quét chỉ bằng camera",
    "fil": "Pag-scan gamit lang ang camera",
  },
  "Camera surface preview": {
    "es": "Vista previa de superficies",
    "zh-Hans": "相机表面预览",
    "zh-Hant": "相機表面預覽",
    "vi": "Xem trước bề mặt qua camera",
    "fil": "Preview ng mga ibabaw sa camera",
  },
  "Undo point or distance": {
    "es": "Deshacer punto o distancia",
    "zh-Hans": "撤销点或距离",
    "zh-Hant": "復原點或距離",
    "vi": "Hoàn tác điểm hoặc khoảng cách",
    "fil": "I-undo ang punto o distansya",
  },
  "Add first point (optional)": {
    "es": "Añadir primer punto (opcional)",
    "zh-Hans": "添加起点（可选）",
    "zh-Hant": "新增起點（選填）",
    "vi": "Thêm điểm đầu (tùy chọn)",
    "fil": "Idagdag ang unang punto (opsyonal)",
  },
  "Add second point": {
    "es": "Añadir segundo punto",
    "zh-Hans": "添加终点",
    "zh-Hant": "新增終點",
    "vi": "Thêm điểm thứ hai",
    "fil": "Idagdag ang ikalawang punto",
  },
  "Move slowly to find surfaces. Keep a clear path; photos and manual assessment are always available.": {
    "es":
        "Muévase despacio para detectar superficies. Mantenga el paso despejado; siempre puede usar fotos y evaluación manual.",
    "zh-Hans": "缓慢移动以寻找表面。保持通道畅通；您随时可以使用照片和手动评估。",
    "zh-Hant": "緩慢移動以尋找表面。保持通道暢通；您隨時可以使用照片和手動評估。",
    "vi":
        "Di chuyển chậm để tìm bề mặt. Giữ lối đi thông thoáng; bạn luôn có thể dùng ảnh và đánh giá thủ công.",
    "fil":
        "Dahan-dahang kumilos para makita ang mga ibabaw. Panatilihing maluwag ang daan; maaari pa ring gumamit ng larawan at manwal na pagtatasa.",
  },
  "Move slowly in good light. Point at a textured surface to restore tracking.": {
    "es":
        "Muévase despacio con buena luz. Apunte a una superficie con detalles para recuperar el seguimiento.",
    "zh-Hans": "在光线充足处缓慢移动。对准有纹理的表面以恢复跟踪。",
    "zh-Hant": "在光線充足處緩慢移動。對準有紋理的表面以恢復追蹤。",
    "vi":
        "Di chuyển chậm ở nơi đủ sáng. Hướng vào bề mặt có hoa văn để khôi phục theo dõi.",
    "fil":
        "Dahan-dahang kumilos sa maliwanag na lugar. Itutok sa ibabaw na may detalye para maibalik ang pagsubaybay.",
  },
  "Aim at the second point on the same highlighted surface, then add it.": {
    "es": "Apunte al segundo punto de la misma superficie resaltada y añádalo.",
    "zh-Hans": "对准同一高亮表面上的终点，然后添加。",
    "zh-Hant": "對準同一醒目表面上的終點，然後新增。",
    "vi": "Hướng vào điểm thứ hai trên cùng bề mặt được tô sáng rồi thêm điểm.",
    "fil":
        "Itutok sa ikalawang punto sa parehong naka-highlight na ibabaw, saka idagdag ito.",
  },
  "Finish to review surfaces, or aim at two points on one highlighted surface to estimate a distance.": {
    "es":
        "Termine para revisar las superficies, o marque dos puntos en una superficie resaltada para estimar una distancia.",
    "zh-Hans": "完成后可查看表面，或在同一高亮表面上选择两点来估算距离。",
    "zh-Hant": "完成後可查看表面，或在同一醒目表面上選擇兩點來估算距離。",
    "vi":
        "Hoàn tất để xem các bề mặt, hoặc chọn hai điểm trên cùng bề mặt được tô sáng để ước tính khoảng cách.",
    "fil":
        "Tapusin para suriin ang mga ibabaw, o pumili ng dalawang punto sa iisang naka-highlight na ibabaw para tantiyahin ang distansya.",
  },
  "Aim at a highlighted surface and try again.": {
    "es": "Apunte a una superficie resaltada e inténtelo de nuevo.",
    "zh-Hans": "对准高亮表面后重试。",
    "zh-Hant": "對準醒目表面後再試。",
    "vi": "Hướng vào bề mặt được tô sáng rồi thử lại.",
    "fil": "Itutok sa naka-highlight na ibabaw at subukan muli.",
  },
  "Distance estimate added. Review it after finishing.": {
    "es": "Estimación de distancia añadida. Revísela al terminar.",
    "zh-Hans": "已添加距离估算。完成后请查看。",
    "zh-Hant": "已新增距離估算。完成後請查看。",
    "vi": "Đã thêm khoảng cách ước tính. Xem lại sau khi hoàn tất.",
    "fil": "Naidagdag ang tantiya ng distansya. Suriin ito pagkatapos.",
  },
  "Use two points on the same surface, 2 cm to 10 m apart. Undo to start again.": {
    "es":
        "Use dos puntos de la misma superficie, separados entre 2 cm y 10 m. Deshaga para empezar de nuevo.",
    "zh-Hans": "请在同一表面上选取间距为2厘米至10米的两点。撤销后可重新开始。",
    "zh-Hant": "請在同一表面上選取間距為2公分至10公尺的兩點。復原後可重新開始。",
    "vi":
        "Chọn hai điểm trên cùng bề mặt, cách nhau từ 2 cm đến 10 m. Hoàn tác để bắt đầu lại.",
    "fil":
        "Gumamit ng dalawang punto sa parehong ibabaw na 2 cm hanggang 10 m ang pagitan. I-undo para magsimulang muli.",
  },
  "Start camera scan": {
    "es": "Iniciar escaneo con cámara",
    "zh-Hans": "开始相机扫描",
    "zh-Hant": "開始相機掃描",
    "vi": "Bắt đầu quét bằng camera",
    "fil": "Simulan ang pag-scan sa camera",
  },
  "This iPhone uses camera-only scanning. Capture surfaces and optional distance estimates.": {
    "es":
        "Este iPhone escanea solo con la cámara. Capture superficies y, si quiere, estime distancias.",
    "zh-Hans": "此iPhone使用仅相机扫描，可采集表面并选择估算距离。",
    "zh-Hant": "此iPhone使用僅相機掃描，可擷取表面並選擇估算距離。",
    "vi":
        "iPhone này quét chỉ bằng camera. Ghi lại bề mặt và tùy chọn ước tính khoảng cách.",
    "fil":
        "Camera lang ang ginagamit ng iPhone na ito sa pag-scan. Kunan ang mga ibabaw at opsyonal na tantiyahin ang distansya.",
  },
  "Camera-only surface model. Identify features yourself; detected patches are not full walls or clearances.": {
    "es":
        "Modelo de superficies obtenido solo con cámara. Identifique los elementos; las zonas detectadas no representan paredes completas ni espacios libres.",
    "zh-Hans": "仅相机表面模型。请自行识别物体；检测到的局部表面并非完整墙壁或通行净空。",
    "zh-Hant": "僅相機表面模型。請自行辨識物體；偵測到的局部表面並非完整牆壁或通行淨空。",
    "vi":
        "Mô hình bề mặt chỉ từ camera. Bạn cần tự xác định vật thể; các mảng phát hiện không phải toàn bộ tường hay khoảng trống sử dụng được.",
    "fil":
        "Modelo ng ibabaw mula sa camera lang. Ikaw ang tutukoy sa mga bagay; hindi buong dingding o maluwag na daanan ang mga natukoy na bahagi.",
  },
  "Estimated distances": {
    "es": "Distancias estimadas",
    "zh-Hans": "估算距离",
    "zh-Hant": "估算距離",
    "vi": "Khoảng cách ước tính",
    "fil": "Mga tinantiyang distansya",
  },
  "These camera estimates stay on this phone. Check important measurements with a tape measure.": {
    "es":
        "Estas estimaciones se guardan en este teléfono. Compruebe las medidas importantes con una cinta métrica.",
    "zh-Hans": "这些相机估算保存在此手机上。请用卷尺核实重要尺寸。",
    "zh-Hant": "這些相機估算保存在此手機上。請用捲尺核實重要尺寸。",
    "vi":
        "Các ước tính này được lưu trên điện thoại này. Kiểm tra số đo quan trọng bằng thước dây.",
    "fil":
        "Nananatili sa teleponong ito ang mga tantiya. Suriin ang mahahalagang sukat gamit ang metro.",
  },
  "Distance {number}: about {metres} m": {
    "es": "Distancia {number}: aprox. {metres} m",
    "zh-Hans": "距离{number}：约{metres}米",
    "zh-Hant": "距離{number}：約{metres}公尺",
    "vi": "Khoảng cách {number}: khoảng {metres} m",
    "fil": "Distansya {number}: humigit-kumulang {metres} m",
  },
  'Scan your bathroom': {
    'es': 'Escanee su baño',
    'zh-Hans': '扫描浴室',
    'zh-Hant': '掃描浴室',
    'vi': 'Quét phòng tắm của bạn',
    'fil': 'I-scan ang iyong banyo',
  },
  'Move slowly and follow the camera guidance. Stay on a safe, clear path. Scan only this bathroom.': {
    'es':
        'Muévase despacio y siga las indicaciones de la cámara. Manténgase en un camino seguro y despejado. Escanee solo este baño.',
    'zh-Hans': '缓慢移动并按照相机指引操作。保持在安全、畅通的路线上。仅扫描这间浴室。',
    'zh-Hant': '緩慢移動並按照相機指引操作。保持在安全、暢通的路線上。僅掃描這間浴室。',
    'vi':
        'Di chuyển chậm và làm theo hướng dẫn của camera. Đi trên lối an toàn, thông thoáng. Chỉ quét phòng tắm này.',
    'fil':
        'Dahan-dahang kumilos at sundin ang gabay ng camera. Manatili sa ligtas at maluwag na daanan. Ang banyong ito lang ang i-scan.',
  },
  'Cancel scan': {
    'es': 'Cancelar escaneo',
    'zh-Hans': '取消扫描',
    'zh-Hant': '取消掃描',
    'vi': 'Hủy quét',
    'fil': 'Kanselahin ang pag-scan',
  },
  'Finish scan': {
    'es': 'Terminar escaneo',
    'zh-Hans': '完成扫描',
    'zh-Hant': '完成掃描',
    'vi': 'Hoàn tất quét',
    'fil': 'Tapusin ang pag-scan',
  },
  'Preparing the simplified 3D room. You will review and confirm it next.': {
    'es':
        'Preparando el modelo 3D simplificado. A continuación podrá revisarlo y confirmarlo.',
    'zh-Hans': '正在生成简化的三维房间模型。接下来请查看并确认。',
    'zh-Hant': '正在建立簡化的三維房間模型。接下來請查看並確認。',
    'vi':
        'Đang chuẩn bị mô hình 3D đơn giản. Tiếp theo bạn sẽ xem và xác nhận.',
    'fil':
        'Inihahanda ang pinasimpleng 3D na silid. Susunod mo itong susuriin at kukumpirmahin.',
  },
  'Move slowly from a safe position. Keep the camera facing walls, floor and fixtures. Do not walk backward or step over obstacles while looking at the screen.': {
    'es':
        'Muévase despacio desde una posición segura. Apunte la cámara a las paredes, el piso y los elementos del baño. No camine hacia atrás ni pase sobre obstáculos mientras mira la pantalla.',
    'zh-Hans': '从安全的位置缓慢移动。相机朝向墙壁、地面和设施。看屏幕时不要倒退行走或跨越障碍物。',
    'zh-Hant': '從安全的位置緩慢移動。相機朝向牆壁、地面和設施。看螢幕時不要倒退行走或跨越障礙物。',
    'vi':
        'Di chuyển chậm từ vị trí an toàn. Hướng camera vào tường, sàn và thiết bị. Không đi lùi hay bước qua vật cản khi nhìn màn hình.',
    'fil':
        'Dahan-dahang kumilos mula sa ligtas na posisyon. Itutok ang camera sa dingding, sahig at mga gamit. Huwag maglakad nang paatras o humakbang sa mga hadlang habang tumitingin sa screen.',
  },
  'This captures an approximate arrangement of surfaces and points. Android does not automatically identify toilets, sinks or doors. You will review the model and identify what it shows.': {
    'es':
        'Esto captura una distribución aproximada de superficies y puntos. Android no identifica automáticamente inodoros, lavabos ni puertas. Usted revisará el modelo e identificará lo que muestra.',
    'zh-Hans': '此功能捕捉表面和采样点的大致布局。Android 不会自动识别马桶、洗手池或门。您需要查看模型并识别其中的物体。',
    'zh-Hant': '此功能擷取表面和取樣點的大致布局。Android 不會自動辨識馬桶、洗手台或門。您需要查看模型並辨識其中的物體。',
    'vi':
        'Tính năng này ghi lại bố cục gần đúng của các bề mặt và điểm. Android không tự nhận diện bồn cầu, bồn rửa hay cửa. Bạn sẽ xem mô hình và xác định các vật thể.',
    'fil':
        'Tinatantiya nito ang ayos ng mga ibabaw at punto. Hindi awtomatikong nakikilala ng Android ang inidoro, lababo o pinto. Susuriin mo ang modelo at tutukuyin ang ipinapakita nito.',
  },
  'Safe at Home does not save or upload raw camera frames. The reviewed geometry stays in your encrypted case on this device. Backgrounding or exceeding three minutes cancels this scan.': {
    'es':
        'Safe at Home no guarda ni sube imágenes sin procesar de la cámara. La geometría revisada queda en su caso cifrado en este dispositivo. Pasar la aplicación a segundo plano o superar tres minutos cancela el escaneo.',
    'zh-Hans':
        'Safe at Home 不会保存或上传原始相机画面。查看后的几何模型保存在此设备上的加密档案中。切换到后台或超过三分钟将取消扫描。',
    'zh-Hant':
        'Safe at Home 不會儲存或上傳原始相機畫面。查看後的幾何模型保存在此裝置上的加密檔案中。切換到背景或超過三分鐘將取消掃描。',
    'vi':
        'Safe at Home không lưu hay tải lên khung hình camera gốc. Hình học đã xem nằm trong hồ sơ mã hóa trên thiết bị này. Chuyển ứng dụng sang nền hoặc quá ba phút sẽ hủy quét.',
    'fil':
        'Hindi nagse-save o nag-a-upload ang Safe at Home ng orihinal na mga frame ng camera. Nananatili ang nasuring hugis sa naka-encrypt na kaso sa device na ito. Makakansela ang pag-scan kapag lumipat sa background o lumampas sa tatlong minuto.',
  },
  'This application runs on Google Play Services for AR (ARCore), which is provided by Google and governed by the Google Privacy Policy.': {
    'es':
        'Esta aplicación usa Google Play Services for AR (ARCore), proporcionado por Google y sujeto a Google Privacy Policy.',
    'zh-Hans':
        '本应用使用 Google 提供的 Google Play Services for AR (ARCore)，并受 Google Privacy Policy 约束。',
    'zh-Hant':
        '本應用程式使用 Google 提供的 Google Play Services for AR (ARCore)，並受 Google Privacy Policy 規範。',
    'vi':
        'Ứng dụng này dùng Google Play Services for AR (ARCore) do Google cung cấp và chịu sự điều chỉnh của Google Privacy Policy.',
    'fil':
        'Gumagamit ang app na ito ng Google Play Services for AR (ARCore), na ibinibigay ng Google at saklaw ng Google Privacy Policy.',
  },
  'Start bathroom scan': {
    'es': 'Iniciar escaneo del baño',
    'zh-Hans': '开始扫描浴室',
    'zh-Hant': '開始掃描浴室',
    'vi': 'Bắt đầu quét phòng tắm',
    'fil': 'Simulan ang pag-scan ng banyo',
  },
  'Cancel': {
    'es': 'Cancelar',
    'zh-Hans': '取消',
    'zh-Hant': '取消',
    'vi': 'Hủy',
    'fil': 'Kanselahin',
  },
  '{surfaces} surfaces · {points} sampled points · {seconds}s remaining. Move slowly. Missing areas stay unknown.': {
    'es':
        '{surfaces} superficies · {points} puntos · quedan {seconds} s. Muévase despacio. Las áreas no capturadas siguen sin conocerse.',
    'zh-Hans':
        '{surfaces} 个表面 · {points} 个采样点 · 剩余 {seconds} 秒。缓慢移动。未扫描的区域仍属未知。',
    'zh-Hant':
        '{surfaces} 個表面 · {points} 個取樣點 · 剩餘 {seconds} 秒。緩慢移動。未掃描的區域仍屬未知。',
    'vi':
        '{surfaces} bề mặt · {points} điểm mẫu · còn {seconds} giây. Di chuyển chậm. Khu vực còn thiếu vẫn chưa xác định.',
    'fil':
        '{surfaces} ibabaw · {points} na punto · {seconds}s na lang. Dahan-dahang kumilos. Hindi pa alam ang mga bahaging hindi na-scan.',
  },
  'Finding position. Move slowly in good light and avoid blank or reflective surfaces. {seconds}s remaining.': {
    'es':
        'Buscando posición. Muévase despacio con buena luz y evite superficies lisas o reflectantes. Quedan {seconds} s.',
    'zh-Hans': '正在定位。在光线充足处缓慢移动，避开空白或反光表面。剩余 {seconds} 秒。',
    'zh-Hant': '正在定位。在光線充足處緩慢移動，避開空白或反光表面。剩餘 {seconds} 秒。',
    'vi':
        'Đang tìm vị trí. Di chuyển chậm nơi đủ sáng, tránh bề mặt trống hoặc phản chiếu. Còn {seconds} giây.',
    'fil':
        'Hinahanap ang posisyon. Dahan-dahang kumilos sa maliwanag na lugar at iwasan ang walang detalye o makintab na ibabaw. {seconds}s na lang.',
  },
  'Live bathroom camera view. Detected surfaces and sampled points are outlined.': {
    'es':
        'Vista de cámara del baño en directo. Se delinean las superficies y los puntos detectados.',
    'zh-Hans': '浴室实时相机画面。已标出检测到的表面和采样点。',
    'zh-Hant': '浴室即時相機畫面。已標出偵測到的表面和取樣點。',
    'vi': 'Hình ảnh trực tiếp phòng tắm. Các bề mặt và điểm mẫu được đánh dấu.',
    'fil':
        'Live na tanaw ng camera sa banyo. May balangkas ang natukoy na mga ibabaw at punto.',
  },
  'Bathroom scan': {
    'es': 'Escaneo del baño',
    'zh-Hans': '浴室扫描',
    'zh-Hant': '浴室掃描',
    'vi': 'Quét phòng tắm',
    'fil': 'Pag-scan ng banyo',
  },
  'Finding position. Move slowly while facing the bathroom.': {
    'es': 'Buscando posición. Muévase despacio apuntando hacia el baño.',
    'zh-Hans': '正在定位。面向浴室缓慢移动。',
    'zh-Hant': '正在定位。面向浴室緩慢移動。',
    'vi': 'Đang tìm vị trí. Di chuyển chậm, hướng về phòng tắm.',
    'fil':
        'Hinahanap ang posisyon. Dahan-dahang kumilos habang nakaharap sa banyo.',
  },
  'Finish and review 3D scan': {
    'es': 'Terminar y revisar escaneo 3D',
    'zh-Hans': '完成并查看三维扫描',
    'zh-Hant': '完成並查看三維掃描',
    'vi': 'Hoàn tất và xem bản quét 3D',
    'fil': 'Tapusin at suriin ang 3D scan',
  },
};
