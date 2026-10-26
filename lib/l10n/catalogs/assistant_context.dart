const assistantContextTranslations = <String, Map<String, String>>{
  'App guidance': {
    'es': 'Guía de la aplicación',
    'zh-Hans': '应用指南',
    'zh-Hant': '應用程式指南',
    'vi': 'Hướng dẫn ứng dụng',
    'fil': 'Gabay sa app',
  },
  'These app steps do not use a language model.': {
    'es': 'Estos pasos de la aplicación no usan un modelo de lenguaje.',
    'zh-Hans': '这些应用操作步骤不使用语言模型。',
    'zh-Hant': '這些應用程式操作步驟不使用語言模型。',
    'vi': 'Các bước trong ứng dụng này không dùng mô hình ngôn ngữ.',
    'fil': 'Hindi gumagamit ng modelo ng wika ang mga hakbang na ito sa app.',
  },
  'Open Help, choose a program, then open Prepare forms. Review the required answers and documents. Saving or sharing a draft does not submit an application.': {
    'es':
        'Abra Ayuda, elija un programa y abra Preparar formularios. Revise las respuestas y los documentos necesarios. Guardar o compartir un borrador no presenta una solicitud.',
    'zh-Hans': '打开“帮助”，选择一个项目，然后打开“准备表格”。查看所需的答案和文档。保存或分享草稿并不等于提交申请。',
    'zh-Hant': '開啟「協助」，選擇一個方案，然後開啟「準備表格」。查看所需的答案和文件。儲存或分享草稿並不等於提交申請。',
    'vi':
        'Mở Trợ giúp, chọn chương trình rồi mở Chuẩn bị biểu mẫu. Xem các câu trả lời và tài liệu cần thiết. Lưu hoặc chia sẻ bản nháp không có nghĩa là đã nộp đơn.',
    'fil':
        'Buksan ang Tulong, pumili ng programa, at buksan ang Ihanda ang mga form. Suriin ang mga kinakailangang sagot at dokumento. Ang pag-save o pagbabahagi ng draft ay hindi pagsusumite ng aplikasyon.',
  },
  'Draft preparation is unavailable in the current app state. Open Plan to check the selected plan.': {
    'es':
        'La preparación del borrador no está disponible en el estado actual. Abra Plan para revisar el plan seleccionado.',
    'zh-Hans': '当前应用状态下无法准备草稿。打开“计划”以查看所选计划。',
    'zh-Hant': '目前應用程式狀態下無法準備草稿。開啟「計畫」以查看所選計畫。',
    'vi':
        'Chưa thể chuẩn bị bản nháp ở trạng thái hiện tại. Mở Kế hoạch để kiểm tra kế hoạch đã chọn.',
    'fil':
        'Hindi magagamit ang paghahanda ng draft sa kasalukuyang kalagayan ng app. Buksan ang Plano upang suriin ang napiling plano.',
  },
  'Check availability': {
    'es': 'Comprobar disponibilidad',
    'zh-Hans': '检查可用性',
    'zh-Hant': '檢查可用性',
    'vi': 'Kiểm tra khả năng sử dụng',
    'fil': 'Tingnan kung magagamit',
  },
  'Retry question': {
    'es': 'Reintentar la pregunta',
    'zh-Hans': '重新提问',
    'zh-Hant': '重新提問',
    'vi': 'Thử lại câu hỏi',
    'fil': 'Subukang muli ang tanong',
  },
  'The model returned a reply the app could not verify. Try again or use App guidance.': {
    'es':
        'El modelo devolvió una respuesta que la aplicación no pudo verificar. Inténtelo de nuevo o use la Guía de la aplicación.',
    'zh-Hans': '模型返回了应用无法验证的回复。请重试或使用“应用指南”。',
    'zh-Hant': '模型傳回了應用程式無法驗證的回覆。請重試或使用「應用程式指南」。',
    'vi':
        'Mô hình trả về câu trả lời mà ứng dụng không thể xác minh. Hãy thử lại hoặc dùng Hướng dẫn ứng dụng.',
    'fil':
        'Hindi ma-verify ng app ang sagot ng modelo. Subukang muli o gamitin ang Gabay sa app.',
  },
  'This phone’s model cannot fit the current app context. Start a new chat without included findings, or use App guidance.': {
    'es':
        'El modelo de este teléfono no puede procesar todo el contexto actual. Inicie un chat nuevo sin observaciones incluidas o use la Guía de la aplicación.',
    'zh-Hans': '此手机的模型无法容纳当前应用信息。请开始不包含观察记录的新对话，或使用“应用指南”。',
    'zh-Hant': '此手機的模型無法容納目前應用程式資訊。請開始不包含觀察記錄的新對話，或使用「應用程式指南」。',
    'vi':
        'Mô hình trên điện thoại không chứa được toàn bộ ngữ cảnh hiện tại. Bắt đầu cuộc trò chuyện mới không kèm ghi nhận hoặc dùng Hướng dẫn ứng dụng.',
    'fil':
        'Hindi kasya sa modelo ng teleponong ito ang kasalukuyang konteksto. Magsimula ng bagong chat na walang kasamang obserbasyon o gamitin ang Gabay sa app.',
  },
  'The on-device model is unavailable. Check availability, or use App guidance.': {
    'es':
        'El modelo del dispositivo no está disponible. Compruebe la disponibilidad o use la Guía de la aplicación.',
    'zh-Hans': '设备端模型不可用。请检查可用性，或使用“应用指南”。',
    'zh-Hant': '裝置端模型無法使用。請檢查可用性，或使用「應用程式指南」。',
    'vi':
        'Mô hình trên thiết bị chưa khả dụng. Kiểm tra khả năng sử dụng hoặc dùng Hướng dẫn ứng dụng.',
    'fil':
        'Hindi magagamit ang modelo sa device. Tingnan kung magagamit na ito o gamitin ang Gabay sa app.',
  },
  'The app could not prepare this request. Use App guidance or reopen the assistant.': {
    'es':
        'La aplicación no pudo preparar esta solicitud. Use la Guía de la aplicación o vuelva a abrir el asistente.',
    'zh-Hans': '应用无法准备此请求。请使用“应用指南”或重新打开助手。',
    'zh-Hant': '應用程式無法準備此要求。請使用「應用程式指南」或重新開啟助理。',
    'vi':
        'Ứng dụng không thể chuẩn bị yêu cầu này. Dùng Hướng dẫn ứng dụng hoặc mở lại trợ lý.',
    'fil':
        'Hindi maihanda ng app ang kahilingang ito. Gamitin ang Gabay sa app o buksang muli ang assistant.',
  },
  'All tasks': {
    'es': 'Todas las tareas',
    'zh-Hans': '所有任务',
    'zh-Hant': '所有任務',
    'vi': 'Tất cả công việc',
    'fil': 'Lahat ng gawain',
  },
  'All programs': {
    'es': 'Todos los programas',
    'zh-Hans': '所有项目',
    'zh-Hant': '所有方案',
    'vi': 'Tất cả chương trình',
    'fil': 'Lahat ng programa',
  },
  'All concerns': {
    'es': 'Todas las observaciones',
    'zh-Hans': '所有问题',
    'zh-Hant': '所有問題',
    'vi': 'Tất cả vấn đề',
    'fil': 'Lahat ng alalahanin',
  },
  'Open Plan to create or select a plan.': {
    'es': 'Abra Plan para crear o seleccionar un plan.',
    'zh-Hans': '打开“计划”以创建或选择计划。',
    'zh-Hant': '開啟「計畫」以建立或選擇計畫。',
    'vi': 'Mở Kế hoạch để tạo hoặc chọn một kế hoạch.',
    'fil': 'Buksan ang Plano para gumawa o pumili ng plano.',
  },
  'Open Tasks to review your next steps.': {
    'es': 'Abra Tareas para revisar los próximos pasos.',
    'zh-Hans': '打开“任务”以查看下一步。',
    'zh-Hant': '開啟「任務」以查看下一步。',
    'vi': 'Mở Công việc để xem các bước tiếp theo.',
    'fil': 'Buksan ang Mga Gawain para suriin ang mga susunod na hakbang.',
  },
  'Open Rooms to review your recorded concerns.': {
    'es': 'Abra Habitaciones para revisar las observaciones registradas.',
    'zh-Hans': '打开“房间”以查看已记录的问题。',
    'zh-Hant': '開啟「房間」以查看已記錄的問題。',
    'vi': 'Mở Phòng để xem các vấn đề đã ghi nhận.',
    'fil': 'Buksan ang Mga Silid para suriin ang mga naitalang alalahanin.',
  },
  'Open Help to review program requirements.': {
    'es': 'Abra Ayuda para revisar los requisitos del programa.',
    'zh-Hans': '打开“帮助”以查看项目要求。',
    'zh-Hant': '開啟「協助」以查看方案要求。',
    'vi': 'Mở Trợ giúp để xem các yêu cầu của chương trình.',
    'fil': 'Buksan ang Tulong para suriin ang mga kinakailangan ng programa.',
  },
  'Open an app section to review the current information.': {
    'es':
        'Abra una sección de la aplicación para revisar la información actual.',
    'zh-Hans': '打开应用中的相应部分以查看当前信息。',
    'zh-Hant': '開啟應用程式中的相關部分以查看目前資訊。',
    'vi': 'Mở một mục trong ứng dụng để xem thông tin hiện tại.',
    'fil':
        'Buksan ang isang seksyon ng app para suriin ang kasalukuyang impormasyon.',
  },
  'Current app context': {
    'es': 'Contexto actual de la aplicación',
    'zh-Hans': '当前应用信息',
    'zh-Hant': '目前應用程式資訊',
    'vi': 'Thông tin hiện tại của ứng dụng',
    'fil': 'Kasalukuyang konteksto ng app',
  },
  'Uses recorded statuses and available sections on this phone. Notes, photos and documents are excluded.': {
    'es':
        'Usa los estados registrados y las secciones disponibles en este teléfono. No incluye notas, fotos ni documentos.',
    'zh-Hans': '使用此手机上已记录的状态和可用功能，不包含笔记、照片和文档。',
    'zh-Hant': '使用此手機上已記錄的狀態和可用功能，不包含筆記、照片和文件。',
    'vi':
        'Dùng trạng thái đã ghi nhận và các mục khả dụng trên điện thoại này. Không bao gồm ghi chú, ảnh và tài liệu.',
    'fil':
        'Ginagamit ang mga naitalang katayuan at magagamit na seksyon sa teleponong ito. Hindi kasama ang mga tala, larawan at dokumento.',
  },
  'Sources': {
    'es': 'Fuentes',
    'zh-Hans': '来源',
    'zh-Hant': '來源',
    'vi': 'Nguồn',
    'fil': 'Mga sanggunian',
  },
  'This reply uses an earlier app state. Ask again for current sources.': {
    'es':
        'Esta respuesta usa un estado anterior de la aplicación. Vuelva a preguntar para consultar las fuentes actuales.',
    'zh-Hans': '此回复基于应用之前的状态。请重新提问以获取当前来源。',
    'zh-Hant': '此回覆依據應用程式先前的狀態。請重新提問以取得目前來源。',
    'vi':
        'Câu trả lời này dùng trạng thái trước đó của ứng dụng. Hãy hỏi lại để có nguồn thông tin hiện tại.',
    'fil':
        'Gumagamit ang sagot na ito ng dating kalagayan ng app. Magtanong muli para sa mga kasalukuyang sanggunian.',
  },
  'Open {section}': {
    'es': 'Abrir {section}',
    'zh-Hans': '打开{section}',
    'zh-Hant': '開啟{section}',
    'vi': 'Mở {section}',
    'fil': 'Buksan ang {section}',
  },
  'Local model trial': {
    'es': 'Prueba de modelo local',
    'zh-Hans': '本地模型试用',
    'zh-Hant': '本機模型試用',
    'vi': 'Thử nghiệm mô hình cục bộ',
    'fil': 'Pagsubok sa lokal na modelo',
  },
  'Import verified model': {
    'es': 'Importar modelo verificado',
    'zh-Hans': '导入已验证的模型',
    'zh-Hant': '匯入已驗證的模型',
    'vi': 'Nhập mô hình đã xác minh',
    'fil': 'Mag-import ng napatunayang modelo',
  },
  'Remove local model': {
    'es': 'Eliminar modelo local',
    'zh-Hans': '移除本地模型',
    'zh-Hant': '移除本機模型',
    'vi': 'Xóa mô hình cục bộ',
    'fil': 'Alisin ang lokal na modelo',
  },
  'Model file stays on this phone.': {
    'es': 'El archivo del modelo permanece en este teléfono.',
    'zh-Hans': '模型文件保留在此手机上。',
    'zh-Hant': '模型檔案保留在此手機上。',
    'vi': 'Tệp mô hình được giữ trên điện thoại này.',
    'fil': 'Nananatili sa teleponong ito ang file ng modelo.',
  },
  'Importing model…': {
    'es': 'Importando modelo…',
    'zh-Hans': '正在导入模型…',
    'zh-Hant': '正在匯入模型…',
    'vi': 'Đang nhập mô hình…',
    'fil': 'Ini-import ang modelo…',
  },
  'The model file could not be imported.': {
    'es': 'No se pudo importar el archivo del modelo.',
    'zh-Hans': '无法导入模型文件。',
    'zh-Hant': '無法匯入模型檔案。',
    'vi': 'Không thể nhập tệp mô hình.',
    'fil': 'Hindi ma-import ang file ng modelo.',
  },
  'Model removed.': {
    'es': 'Modelo eliminado.',
    'zh-Hans': '模型已移除。',
    'zh-Hant': '模型已移除。',
    'vi': 'Đã xóa mô hình.',
    'fil': 'Naalis na ang modelo.',
  },
  'Model installed.': {
    'es': 'Modelo instalado.',
    'zh-Hans': '模型已安装。',
    'zh-Hant': '模型已安裝。',
    'vi': 'Đã cài đặt mô hình.',
    'fil': 'Naka-install na ang modelo.',
  },
  'Context changed. Ask again for current information.': {
    'es':
        'El contexto cambió. Vuelva a preguntar para obtener información actual.',
    'zh-Hans': '信息已发生变化。请重新提问以获取当前信息。',
    'zh-Hant': '資訊已發生變更。請重新提問以取得目前資訊。',
    'vi': 'Thông tin đã thay đổi. Hãy hỏi lại để có thông tin hiện tại.',
    'fil':
        'Nagbago ang konteksto. Magtanong muli para sa kasalukuyang impormasyon.',
  },
};
