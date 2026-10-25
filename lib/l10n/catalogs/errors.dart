const errorsTranslations = <String, Map<String, String>>{
  "Enter your password again before deleting your account.": {
    "es": "Vuelva a introducir su contraseña antes de eliminar la cuenta.",
    "zh-Hans": "删除账户前，请再次输入密码。",
    "zh-Hant": "刪除帳戶前，請再次輸入密碼。",
    "vi": "Nhập lại mật khẩu trước khi xóa tài khoản.",
    "fil": "Ilagay muli ang password bago burahin ang account.",
  },
  "This account is closed. Use the saved deletion receipt to check completion.": {
    "es":
        "Esta cuenta está cerrada. Use el comprobante de eliminación guardado para comprobar si terminó.",
    "zh-Hans": "此账户已关闭。请使用保存的删除凭据检查是否完成。",
    "zh-Hant": "此帳戶已關閉。請使用儲存的刪除憑據檢查是否完成。",
    "vi": "Tài khoản đã đóng. Dùng biên nhận xóa đã lưu để kiểm tra hoàn tất.",
    "fil":
        "Sarado na ang account. Gamitin ang naka-save na resibo ng pagbura para tingnan kung tapos na.",
  },
  "This deletion receipt is unavailable. Contact the app operator if confirmation was already sent.": {
    "es":
        "Este comprobante de eliminación no está disponible. Contacte al operador de la aplicación si ya envió la confirmación.",
    "zh-Hans": "此删除凭据不可用。如果已发送确认，请联系应用运营者。",
    "zh-Hant": "此刪除憑據無法使用。如果已傳送確認，請聯絡應用程式營運者。",
    "vi":
        "Biên nhận xóa này không khả dụng. Liên hệ người vận hành ứng dụng nếu đã gửi xác nhận.",
    "fil":
        "Hindi available ang resibo ng pagbura. Makipag-ugnayan sa operator ng app kung naipadala na ang kumpirmasyon.",
  },
  "The deletion preview expired. Review a new preview before confirming.": {
    "es":
        "La vista previa de eliminación venció. Revise una nueva antes de confirmar.",
    "zh-Hans": "删除预览已过期。请查看新预览后再确认。",
    "zh-Hant": "刪除預覽已過期。請查看新預覽後再確認。",
    "vi": "Bản xem trước xóa đã hết hạn. Xem bản mới trước khi xác nhận.",
    "fil":
        "Nag-expire ang preview ng pagbura. Suriin ang bagong preview bago kumpirmahin.",
  },
  "Account data changed. Review a new deletion preview before confirming.": {
    "es":
        "Los datos de la cuenta cambiaron. Revise una nueva vista previa de eliminación antes de confirmar.",
    "zh-Hans": "账户资料已更改。请查看新的删除预览后再确认。",
    "zh-Hant": "帳戶資料已變更。請查看新的刪除預覽後再確認。",
    "vi":
        "Dữ liệu tài khoản đã thay đổi. Xem bản xem trước xóa mới trước khi xác nhận.",
    "fil":
        "Nagbago ang datos ng account. Suriin ang bagong preview ng pagbura bago kumpirmahin.",
  },
  "The deletion outcome is unknown. Check the retained receipt or reload the case before deciding whether to retry.": {
    "es":
        "Se desconoce el resultado de la eliminación. Compruebe el recibo conservado o recargue el caso antes de decidir si reintenta.",
    "zh-Hans": "删除结果未知。请检查保留的凭据或重新载入个案，再决定是否重试。",
    "zh-Hant": "刪除結果未知。請檢查保留的憑據或重新載入個案，再決定是否重試。",
    "vi":
        "Chưa biết kết quả xóa. Kiểm tra biên nhận đã giữ hoặc tải lại hồ sơ trước khi quyết định thử lại.",
    "fil":
        "Hindi pa alam ang resulta ng pagbura. Tingnan ang natirang resibo o i-load muli ang kaso bago magpasya kung uulit.",
  },
  "The assessment changed. Reload and reconcile your local changes.": {
    "es": "La evaluación cambió. Recargue y concilie sus cambios locales.",
    "zh-Hans": "评估已更改。请重新载入并核对本机修改。",
    "zh-Hant": "評估已變更。請重新載入並核對本機修改。",
    "vi":
        "Đánh giá đã thay đổi. Tải lại và đối chiếu các thay đổi trên thiết bị.",
    "fil":
        "Nagbago ang pagtatasa. I-load muli at pagtugmain ang mga lokal mong pagbabago.",
  },
  "This assessment attempt refers to different changes. Reload before continuing.": {
    "es":
        "Este intento de evaluación corresponde a otros cambios. Recargue antes de continuar.",
    "zh-Hans": "此次评估尝试对应不同的修改。请重新载入后再继续。",
    "zh-Hant": "此次評估嘗試對應不同的修改。請重新載入後再繼續。",
    "vi":
        "Lần thử đánh giá này liên quan đến thay đổi khác. Tải lại trước khi tiếp tục.",
    "fil":
        "Tumutukoy ang pagtatangkang ito sa ibang pagbabago. I-load muli bago magpatuloy.",
  },
  "This case reached its assessment history limit. Contact the app operator.": {
    "es":
        "Este caso alcanzó su límite de historial de evaluación. Contacte al operador de la aplicación.",
    "zh-Hans": "此个案已达到评估历史上限。请联系应用运营者。",
    "zh-Hant": "此個案已達到評估歷程上限。請聯絡應用程式營運者。",
    "vi":
        "Hồ sơ đã đạt giới hạn lịch sử đánh giá. Liên hệ người vận hành ứng dụng.",
    "fil":
        "Naabot ng kaso ang limitasyon ng kasaysayan ng pagtatasa. Makipag-ugnayan sa operator ng app.",
  },
  "Use the assessment editor to preserve measurements and review history.": {
    "es":
        "Use el editor de evaluación para conservar las mediciones y el historial de revisión.",
    "zh-Hans": "请使用评估编辑器以保留测量和审核历史。",
    "zh-Hant": "請使用評估編輯器以保留測量和審查歷程。",
    "vi": "Dùng trình sửa đánh giá để giữ số đo và lịch sử xem xét.",
    "fil":
        "Gamitin ang editor ng pagtatasa para mapanatili ang mga sukat at kasaysayan ng pagsusuri.",
  },
  "The photo markings changed. Reload and review them before saving.": {
    "es":
        "Las marcas de la foto cambiaron. Recárguelas y revíselas antes de guardar.",
    "zh-Hans": "照片标记已更改。请重新载入并核对后再保存。",
    "zh-Hant": "照片標記已變更。請重新載入並核對後再儲存。",
    "vi": "Dấu trên ảnh đã thay đổi. Tải lại và xem xét trước khi lưu.",
    "fil":
        "Nagbago ang mga marka sa larawan. I-load muli at suriin bago mag-save.",
  },
  "This photo has saved markings. Use the current draft export flow.": {
    "es":
        "Esta foto tiene marcas guardadas. Use el flujo actual de exportación de borradores.",
    "zh-Hans": "此照片有已保存标记。请使用当前的草稿导出流程。",
    "zh-Hant": "此照片有已儲存標記。請使用目前的草稿匯出流程。",
    "vi": "Ảnh này có dấu đã lưu. Dùng quy trình xuất bản nháp hiện tại.",
    "fil":
        "May naka-save na mga marka ang larawan. Gamitin ang kasalukuyang proseso ng pag-export ng draft.",
  },
  "Review the current photo and its markings before export.": {
    "es": "Revise la foto actual y sus marcas antes de exportar.",
    "zh-Hans": "导出前请核对当前照片及标记。",
    "zh-Hant": "匯出前請核對目前照片及標記。",
    "vi": "Xem ảnh hiện tại và các dấu trước khi xuất.",
    "fil": "Suriin ang kasalukuyang larawan at mga marka bago i-export.",
  },
  "Program answers changed. Reload and reconcile your answers.": {
    "es":
        "Las respuestas del programa cambiaron. Recargue y concilie sus respuestas.",
    "zh-Hans": "项目答案已更改。请重新载入并核对您的答案。",
    "zh-Hant": "計畫答案已變更。請重新載入並核對您的答案。",
    "vi":
        "Câu trả lời chương trình đã thay đổi. Tải lại và đối chiếu câu trả lời.",
    "fil":
        "Nagbago ang mga sagot sa programa. I-load muli at pagtugmain ang mga sagot mo.",
  },
  "These questions changed. Review the current questionnaire.": {
    "es": "Estas preguntas cambiaron. Revise el cuestionario actual.",
    "zh-Hans": "这些问题已更改。请查看当前问卷。",
    "zh-Hant": "這些問題已變更。請查看目前問卷。",
    "vi": "Các câu hỏi đã thay đổi. Xem bảng câu hỏi hiện tại.",
    "fil": "Nagbago ang mga tanong. Suriin ang kasalukuyang talatanungan.",
  },
  "The save result is uncertain. Keep your local answers and reload before reconciling.": {
    "es":
        "El resultado del guardado es incierto. Conserve sus respuestas locales y recargue antes de conciliarlas.",
    "zh-Hans": "保存结果不确定。请保留本机答案，重新载入后再核对。",
    "zh-Hant": "儲存結果不確定。請保留本機答案，重新載入後再核對。",
    "vi":
        "Chưa chắc kết quả lưu. Giữ câu trả lời trên thiết bị và tải lại trước khi đối chiếu.",
    "fil":
        "Hindi tiyak ang resulta ng pag-save. Panatilihin ang lokal mong mga sagot at i-load muli bago pagtugmain.",
  },
  "Use the current draft workflow to include saved program answers.": {
    "es":
        "Use el flujo actual de borradores para incluir las respuestas del programa guardadas.",
    "zh-Hans": "请使用当前的草稿流程以包含已保存的项目答案。",
    "zh-Hant": "請使用目前的草稿流程以包含已儲存的計畫答案。",
    "vi":
        "Dùng quy trình bản nháp hiện tại để đưa câu trả lời chương trình đã lưu vào.",
    "fil":
        "Gamitin ang kasalukuyang proseso ng draft upang maisama ang naka-save na mga sagot sa programa.",
  },
  "The request was invalid. Review the case and try again.": {
    "es": "La solicitud no era válida. Revise el caso e inténtelo de nuevo.",
    "zh-Hans": "请求无效。请核对个案后重试。",
    "zh-Hant": "要求無效。請核對個案後重試。",
    "vi": "Yêu cầu không hợp lệ. Kiểm tra hồ sơ và thử lại.",
    "fil": "Hindi wasto ang request. Suriin ang kaso at subukang muli.",
  },
  "Sign in before continuing.": {
    "es": "Inicie sesión antes de continuar.",
    "zh-Hans": "请先登录再继续。",
    "zh-Hant": "請先登入再繼續。",
    "vi": "Đăng nhập trước khi tiếp tục.",
    "fil": "Mag-sign in bago magpatuloy.",
  },
  "This case is unavailable to the signed-in user.": {
    "es": "Este caso no está disponible para el usuario que inició sesión.",
    "zh-Hans": "当前登录用户无法访问此个案。",
    "zh-Hant": "目前登入使用者無法存取此個案。",
    "vi": "Người dùng đang đăng nhập không truy cập được hồ sơ này.",
    "fil": "Hindi available ang kasong ito sa naka-sign in na gumagamit.",
  },
  "The selected program is unavailable. Refresh the programs.": {
    "es":
        "El programa seleccionado no está disponible. Actualice los programas.",
    "zh-Hans": "所选项目不可用。请刷新项目列表。",
    "zh-Hant": "所選計畫無法使用。請重新整理計畫清單。",
    "vi": "Chương trình đã chọn không khả dụng. Làm mới các chương trình.",
    "fil": "Hindi available ang napiling programa. I-refresh ang mga programa.",
  },
  "The endpoint was not found. Check the service configuration.": {
    "es":
        "No se encontró el punto de acceso. Compruebe la configuración del servicio.",
    "zh-Hans": "找不到服务端点。请检查服务配置。",
    "zh-Hant": "找不到服務端點。請檢查服務設定。",
    "vi": "Không tìm thấy điểm cuối. Kiểm tra cấu hình dịch vụ.",
    "fil": "Hindi mahanap ang endpoint. Suriin ang configuration ng serbisyo.",
  },
  "The saved case changed. Reload it before continuing.": {
    "es": "El caso guardado cambió. Recárguelo antes de continuar.",
    "zh-Hans": "已保存的个案已更改。请重新载入后再继续。",
    "zh-Hant": "已儲存的個案已變更。請重新載入後再繼續。",
    "vi": "Hồ sơ đã lưu đã thay đổi. Tải lại trước khi tiếp tục.",
    "fil": "Nagbago ang naka-save na kaso. I-load muli bago magpatuloy.",
  },
  "This case identifier is unavailable. Reload the selected case to recover an earlier attempt, or start a new case with a fresh identifier.": {
    "es":
        "Este identificador de caso no está disponible. Recargue el caso para recuperar un intento anterior o inicie uno nuevo con otro identificador.",
    "zh-Hans": "此个案编号不可用。请重新载入所选个案以恢复先前尝试，或使用新编号建立新个案。",
    "zh-Hant": "此個案編號無法使用。請重新載入所選個案以復原先前嘗試，或使用新編號建立新個案。",
    "vi":
        "Mã hồ sơ không khả dụng. Tải lại hồ sơ đã chọn để khôi phục lần thử trước, hoặc tạo hồ sơ mới với mã mới.",
    "fil":
        "Hindi available ang identifier ng kaso. I-load muli ang napiling kaso para ibalik ang naunang pagsubok, o magsimula ng bagong kaso na may bagong identifier.",
  },
  "The case save outcome is unknown. Reload this same case identifier before deciding whether to save again.": {
    "es":
        "Se desconoce el resultado del guardado del caso. Recargue este mismo identificador antes de decidir si vuelve a guardar.",
    "zh-Hans": "个案保存结果未知。请重新载入同一个案编号，再决定是否重新保存。",
    "zh-Hant": "個案儲存結果未知。請重新載入同一個案編號，再決定是否重新儲存。",
    "vi":
        "Chưa biết kết quả lưu hồ sơ. Tải lại đúng mã hồ sơ này trước khi quyết định lưu lại.",
    "fil":
        "Hindi pa alam ang resulta ng pag-save ng kaso. I-load muli ang parehong identifier bago magpasya kung muling magse-save.",
  },
  "This plan name changed elsewhere. Compare the saved name with your edit before trying again.": {
    "es":
        "El nombre del plan cambió en otro lugar. Compare el nombre guardado con su edición antes de reintentar.",
    "zh-Hans": "此计划名称已在别处更改。请比较已保存名称和您的修改后再重试。",
    "zh-Hant": "此計畫名稱已在別處變更。請比較已儲存名稱和您的修改後再重試。",
    "vi":
        "Tên kế hoạch đã thay đổi ở nơi khác. So sánh tên đã lưu với chỉnh sửa của bạn trước khi thử lại.",
    "fil":
        "Nagbago ang pangalan ng plano sa ibang lugar. Ihambing ang naka-save na pangalan sa pagbabago mo bago subukan ulit.",
  },
  "The plan name save could not be confirmed. Keep your edit and check the saved name before retrying.": {
    "es":
        "No se pudo confirmar el guardado del nombre. Conserve su edición y compruebe el nombre guardado antes de reintentar.",
    "zh-Hans": "无法确认计划名称已保存。请保留修改，并检查已保存名称后再重试。",
    "zh-Hant": "無法確認計畫名稱已儲存。請保留修改，並檢查已儲存名稱後再重試。",
    "vi":
        "Chưa xác nhận được lưu tên kế hoạch. Giữ chỉnh sửa và kiểm tra tên đã lưu trước khi thử lại.",
    "fil":
        "Hindi makumpirma ang pag-save ng pangalan ng plano. Panatilihin ang pagbabago at suriin ang naka-save na pangalan bago subukan ulit.",
  },
  "The image change outcome is unknown. Reload the case and evidence catalog before changing the image again.": {
    "es":
        "Se desconoce el resultado del cambio de imagen. Recargue el caso y el catálogo de pruebas antes de volver a cambiarla.",
    "zh-Hans": "图像修改结果未知。再次更改图像前，请重新载入个案和佐证目录。",
    "zh-Hant": "影像修改結果未知。再次變更影像前，請重新載入個案和佐證目錄。",
    "vi":
        "Chưa biết kết quả đổi ảnh. Tải lại hồ sơ và danh mục bằng chứng trước khi đổi ảnh lần nữa.",
    "fil":
        "Hindi pa alam ang resulta ng pagbabago sa larawan. I-load muli ang kaso at katalogo ng ebidensya bago baguhin ulit ang larawan.",
  },
  "The image could not be processed. Choose a supported JPEG or PNG within the image limits.": {
    "es":
        "No se pudo procesar la imagen. Elija un JPEG o PNG compatible dentro de los límites.",
    "zh-Hans": "无法处理图像。请选择符合限制的受支持 JPEG 或 PNG 文件。",
    "zh-Hant": "無法處理影像。請選擇符合限制的支援 JPEG 或 PNG 檔案。",
    "vi":
        "Không xử lý được ảnh. Chọn JPEG hoặc PNG được hỗ trợ trong giới hạn ảnh.",
    "fil":
        "Hindi maproseso ang larawan. Pumili ng suportadong JPEG o PNG na pasok sa mga limitasyon.",
  },
  "Too many requests. Wait before trying this same action again.": {
    "es": "Demasiadas solicitudes. Espere antes de repetir esta misma acción.",
    "zh-Hans": "请求过多。请稍候再尝试同一操作。",
    "zh-Hant": "要求過多。請稍候再嘗試同一操作。",
    "vi": "Quá nhiều yêu cầu. Chờ trước khi thử lại cùng thao tác.",
    "fil":
        "Masyadong maraming request. Maghintay bago subukan muli ang parehong gawain.",
  },
  "Another image is being processed. Wait before trying again.": {
    "es": "Se está procesando otra imagen. Espere antes de reintentar.",
    "zh-Hans": "正在处理另一张图像。请稍候再重试。",
    "zh-Hant": "正在處理另一張影像。請稍候再重試。",
    "vi": "Một ảnh khác đang được xử lý. Chờ trước khi thử lại.",
    "fil": "May ibang larawang pinoproseso. Maghintay bago subukang muli.",
  },
  "The case or program changed since this draft was started. Start a new draft.": {
    "es":
        "El caso o programa cambió desde que comenzó este borrador. Inicie uno nuevo.",
    "zh-Hans": "自此草稿开始后，个案或项目已更改。请开始新草稿。",
    "zh-Hant": "自此草稿開始後，個案或計畫已變更。請開始新草稿。",
    "vi":
        "Hồ sơ hoặc chương trình đã thay đổi từ khi bắt đầu bản nháp. Tạo bản nháp mới.",
    "fil":
        "Nagbago ang kaso o programa mula nang simulan ang draft. Magsimula ng bagong draft.",
  },
  "The request history changed. Reload it before recording another update.": {
    "es":
        "El historial de la solicitud cambió. Recárguelo antes de registrar otra actualización.",
    "zh-Hans": "申请历史已更改。请重新载入后再记录更新。",
    "zh-Hant": "申請歷程已變更。請重新載入後再記錄更新。",
    "vi": "Lịch sử yêu cầu đã thay đổi. Tải lại trước khi ghi cập nhật khác.",
    "fil":
        "Nagbago ang kasaysayan ng kahilingan. I-load muli bago magtala ng panibagong update.",
  },
  "This update identifier already refers to a different saved report. Read the history before continuing.": {
    "es":
        "Este identificador de actualización ya corresponde a otro informe guardado. Lea el historial antes de continuar.",
    "zh-Hans": "此更新编号已用于另一份保存的报告。请查看历史后再继续。",
    "zh-Hant": "此更新編號已用於另一份儲存的報告。請查看歷程後再繼續。",
    "vi":
        "Mã cập nhật này đã liên kết với báo cáo đã lưu khác. Đọc lịch sử trước khi tiếp tục.",
    "fil":
        "Tumutukoy na ang identifier ng update sa ibang naka-save na ulat. Basahin ang kasaysayan bago magpatuloy.",
  },
  "This case has reached its request history limit.": {
    "es": "Este caso alcanzó su límite de historial de solicitudes.",
    "zh-Hans": "此个案已达到申请历史上限。",
    "zh-Hant": "此個案已達到申請歷程上限。",
    "vi": "Hồ sơ này đã đạt giới hạn lịch sử yêu cầu.",
    "fil": "Naabot ng kaso ang limitasyon ng kasaysayan ng kahilingan.",
  },
  "The update outcome is unknown. Read this request history and compare the retained update before deciding whether to retry.": {
    "es":
        "Se desconoce el resultado de la actualización. Lea el historial y compare la actualización conservada antes de decidir si reintenta.",
    "zh-Hans": "更新结果未知。请查看申请历史并比较保留的更新，再决定是否重试。",
    "zh-Hant": "更新結果未知。請查看申請歷程並比較保留的更新，再決定是否重試。",
    "vi":
        "Chưa biết kết quả cập nhật. Đọc lịch sử yêu cầu và so sánh cập nhật đã giữ trước khi quyết định thử lại.",
    "fil":
        "Hindi pa alam ang resulta ng update. Basahin ang kasaysayan at ihambing ang natirang update bago magpasya kung uulit.",
  },
  "Reviewed form answers are unavailable for this program.": {
    "es":
        "Las respuestas revisadas del formulario no están disponibles para este programa.",
    "zh-Hans": "此项目没有可用的已审核表格答案。",
    "zh-Hant": "此計畫沒有可用的已審查表格答案。",
    "vi": "Không có câu trả lời biểu mẫu đã xem xét cho chương trình này.",
    "fil":
        "Hindi available ang mga nasuring sagot sa form para sa programang ito.",
  },
  "The form changed. Reload it before saving answers.": {
    "es": "El formulario cambió. Recárguelo antes de guardar respuestas.",
    "zh-Hans": "表格已更改。请重新载入后再保存答案。",
    "zh-Hant": "表格已變更。請重新載入後再儲存答案。",
    "vi": "Biểu mẫu đã thay đổi. Tải lại trước khi lưu câu trả lời.",
    "fil": "Nagbago ang form. I-load muli bago mag-save ng mga sagot.",
  },
  "The saved answers changed. Reload them before saving.": {
    "es": "Las respuestas guardadas cambiaron. Recárguelas antes de guardar.",
    "zh-Hans": "已保存答案已更改。请重新载入后再保存。",
    "zh-Hant": "已儲存答案已變更。請重新載入後再儲存。",
    "vi": "Câu trả lời đã lưu đã thay đổi. Tải lại trước khi lưu.",
    "fil": "Nagbago ang mga naka-save na sagot. I-load muli bago mag-save.",
  },
  "Review and save the form answers for the current case and form before preparing a draft.": {
    "es":
        "Revise y guarde las respuestas del caso y formulario actuales antes de preparar un borrador.",
    "zh-Hans": "准备草稿前，请核对并保存当前个案和表格的答案。",
    "zh-Hant": "準備草稿前，請核對並儲存目前個案和表格的答案。",
    "vi":
        "Xem xét và lưu câu trả lời cho hồ sơ và biểu mẫu hiện tại trước khi chuẩn bị bản nháp.",
    "fil":
        "Suriin at i-save ang mga sagot para sa kasalukuyang kaso at form bago gumawa ng draft.",
  },
  "The save outcome is unknown. Reload the case and form answers before saving again.": {
    "es":
        "Se desconoce el resultado del guardado. Recargue el caso y las respuestas del formulario antes de volver a guardar.",
    "zh-Hans": "保存结果未知。再次保存前，请重新载入个案和表格答案。",
    "zh-Hant": "儲存結果未知。再次儲存前，請重新載入個案和表格答案。",
    "vi":
        "Chưa biết kết quả lưu. Tải lại hồ sơ và câu trả lời biểu mẫu trước khi lưu lại.",
    "fil":
        "Hindi pa alam ang resulta ng pag-save. I-load muli ang kaso at mga sagot sa form bago muling mag-save.",
  },
  "The requested private file is unavailable.": {
    "es": "El archivo privado solicitado no está disponible.",
    "zh-Hans": "所请求的私密文件不可用。",
    "zh-Hant": "所要求的私密檔案無法使用。",
    "vi": "Tệp riêng tư được yêu cầu không khả dụng.",
    "fil": "Hindi available ang hinihinging pribadong file.",
  },
  "The evidence changed. Reload it and review your selection again.": {
    "es": "Las pruebas cambiaron. Recárguelas y revise su selección de nuevo.",
    "zh-Hans": "佐证资料已更改。请重新载入并再次核对选择。",
    "zh-Hant": "佐證資料已變更。請重新載入並再次核對選擇。",
    "vi": "Bằng chứng đã thay đổi. Tải lại và xem xét lại lựa chọn.",
    "fil": "Nagbago ang ebidensya. I-load muli at suriin ulit ang pinili mo.",
  },
  "The saved answers changed. Reload them before preparing a draft.": {
    "es":
        "Las respuestas guardadas cambiaron. Recárguelas antes de preparar un borrador.",
    "zh-Hans": "已保存答案已更改。请重新载入后再准备草稿。",
    "zh-Hant": "已儲存答案已變更。請重新載入後再準備草稿。",
    "vi":
        "Câu trả lời đã lưu đã thay đổi. Tải lại trước khi chuẩn bị bản nháp.",
    "fil":
        "Nagbago ang mga naka-save na sagot. I-load muli bago gumawa ng draft.",
  },
  "This export attempt no longer matches the current case. Review the changes before starting another attempt.": {
    "es":
        "Este intento de exportación ya no coincide con el caso actual. Revise los cambios antes de iniciar otro intento.",
    "zh-Hans": "此次导出尝试已不符合当前个案。请审核修改后再开始新的尝试。",
    "zh-Hant": "此次匯出嘗試已不符合目前個案。請審查修改後再開始新的嘗試。",
    "vi":
        "Lần xuất này không còn khớp với hồ sơ hiện tại. Xem xét thay đổi trước khi thử lần khác.",
    "fil":
        "Hindi na tugma ang pag-export na ito sa kasalukuyang kaso. Suriin ang mga pagbabago bago magsimula ng panibagong pagsubok.",
  },
  "This draft download has expired. Prepare a new draft from the current case.": {
    "es":
        "La descarga de este borrador venció. Prepare uno nuevo con el caso actual.",
    "zh-Hans": "此草稿下载已过期。请根据当前个案准备新草稿。",
    "zh-Hant": "此草稿下載已過期。請根據目前個案準備新草稿。",
    "vi":
        "Liên kết tải bản nháp đã hết hạn. Chuẩn bị bản nháp mới từ hồ sơ hiện tại.",
    "fil":
        "Nag-expire ang pag-download ng draft. Gumawa ng bagong draft mula sa kasalukuyang kaso.",
  },
  "Review the selected evidence before preparing the draft.": {
    "es": "Revise las pruebas seleccionadas antes de preparar el borrador.",
    "zh-Hans": "准备草稿前请核对所选佐证资料。",
    "zh-Hant": "準備草稿前請核對所選佐證資料。",
    "vi": "Xem xét bằng chứng đã chọn trước khi chuẩn bị bản nháp.",
    "fil": "Suriin ang napiling ebidensya bago gumawa ng draft.",
  },
  "Another draft is being prepared. Wait and retry this same attempt.": {
    "es":
        "Se está preparando otro borrador. Espere y repita este mismo intento.",
    "zh-Hans": "正在准备另一份草稿。请稍候再重试同一尝试。",
    "zh-Hant": "正在準備另一份草稿。請稍候再重試同一嘗試。",
    "vi":
        "Một bản nháp khác đang được chuẩn bị. Chờ rồi thử lại đúng lần thử này.",
    "fil":
        "May ibang draft na inihahanda. Maghintay at ulitin ang parehong pagsubok.",
  },
  "Private storage has reached its limit. Contact the app operator before retrying.": {
    "es":
        "El almacenamiento privado alcanzó su límite. Contacte al operador de la aplicación antes de reintentar.",
    "zh-Hans": "私密存储已达到上限。重试前请联系应用运营者。",
    "zh-Hant": "私密儲存已達到上限。重試前請聯絡應用程式營運者。",
    "vi":
        "Bộ nhớ riêng tư đã đạt giới hạn. Liên hệ người vận hành ứng dụng trước khi thử lại.",
    "fil":
        "Naabot ang limitasyon ng pribadong storage. Makipag-ugnayan sa operator ng app bago subukan ulit.",
  },
  "The request was too large.": {
    "es": "La solicitud era demasiado grande.",
    "zh-Hans": "请求过大。",
    "zh-Hant": "要求過大。",
    "vi": "Yêu cầu quá lớn.",
    "fil": "Masyadong malaki ang request.",
  },
  "The service could not read the request format.": {
    "es": "El servicio no pudo leer el formato de la solicitud.",
    "zh-Hans": "服务无法读取请求格式。",
    "zh-Hant": "服務無法讀取要求格式。",
    "vi": "Dịch vụ không đọc được định dạng yêu cầu.",
    "fil": "Hindi mabasa ng serbisyo ang format ng request.",
  },
  "The service could not accept this request method.": {
    "es": "El servicio no pudo aceptar este método de solicitud.",
    "zh-Hans": "服务无法接受此请求方法。",
    "zh-Hant": "服務無法接受此要求方法。",
    "vi": "Dịch vụ không chấp nhận phương thức yêu cầu này.",
    "fil": "Hindi matanggap ng serbisyo ang pamamaraang ito ng request.",
  },
  "The service could not finish the request. Try again.": {
    "es": "El servicio no pudo completar la solicitud. Inténtelo de nuevo.",
    "zh-Hans": "服务未能完成请求。请重试。",
    "zh-Hant": "服務未能完成要求。請重試。",
    "vi": "Dịch vụ không hoàn tất được yêu cầu. Thử lại.",
    "fil": "Hindi matapos ng serbisyo ang request. Subukang muli.",
  },
  "The service is temporarily unavailable. Try again later.": {
    "es": "El servicio no está disponible temporalmente. Inténtelo más tarde.",
    "zh-Hans": "服务暂时不可用。请稍后重试。",
    "zh-Hant": "服務暫時無法使用。請稍後重試。",
    "vi": "Dịch vụ tạm thời không khả dụng. Thử lại sau.",
    "fil": "Pansamantalang hindi available ang serbisyo. Subukang muli mamaya.",
  },
  "The request timed out. Retry the same preparation attempt.": {
    "es":
        "La solicitud agotó el tiempo de espera. Repita el mismo intento de preparación.",
    "zh-Hans": "请求超时。请重试同一次准备操作。",
    "zh-Hant": "要求逾時。請重試同一次準備操作。",
    "vi": "Yêu cầu đã hết thời gian chờ. Thử lại đúng lần chuẩn bị này.",
    "fil":
        "Nag-time out ang request. Ulitin ang parehong pagtatangkang paghahanda.",
  },
  "Unable to reach the service. Try again when connected.": {
    "es":
        "No se pudo conectar con el servicio. Reintente cuando tenga conexión.",
    "zh-Hans": "无法连接服务。请联网后重试。",
    "zh-Hant": "無法連線服務。請連線後重試。",
    "vi": "Không kết nối được dịch vụ. Thử lại khi có kết nối.",
    "fil": "Hindi makakonekta sa serbisyo. Subukang muli kapag nakakonekta na.",
  },
  "The service response was too large. Try again.": {
    "es": "La respuesta del servicio era demasiado grande. Inténtelo de nuevo.",
    "zh-Hans": "服务响应过大。请重试。",
    "zh-Hant": "服務回應過大。請重試。",
    "vi": "Phản hồi dịch vụ quá lớn. Thử lại.",
    "fil": "Masyadong malaki ang tugon ng serbisyo. Subukang muli.",
  },
  "The service destination changed. Check the service configuration.": {
    "es": "El destino del servicio cambió. Compruebe su configuración.",
    "zh-Hans": "服务地址已更改。请检查服务配置。",
    "zh-Hant": "服務位址已變更。請檢查服務設定。",
    "vi": "Địa chỉ dịch vụ đã thay đổi. Kiểm tra cấu hình dịch vụ.",
    "fil":
        "Nagbago ang destinasyon ng serbisyo. Suriin ang configuration nito.",
  },
  "The case or selected program changed. Refresh before continuing.": {
    "es":
        "El caso o el programa seleccionado cambió. Actualice antes de continuar.",
    "zh-Hans": "个案或所选项目已更改。请刷新后再继续。",
    "zh-Hant": "個案或所選計畫已變更。請重新整理後再繼續。",
    "vi":
        "Hồ sơ hoặc chương trình đã chọn đã thay đổi. Làm mới trước khi tiếp tục.",
    "fil": "Nagbago ang kaso o napiling programa. I-refresh bago magpatuloy.",
  },
  "The service returned an unexpected response. Try again.": {
    "es": "El servicio devolvió una respuesta inesperada. Inténtelo de nuevo.",
    "zh-Hans": "服务返回了意外响应。请重试。",
    "zh-Hant": "服務傳回了非預期回應。請重試。",
    "vi": "Dịch vụ trả về phản hồi không mong đợi. Thử lại.",
    "fil": "Nagbalik ang serbisyo ng hindi inaasahang tugon. Subukang muli.",
  },
  "This action could not be confirmed. Keep your local work and check saved state before trying again.": {
    "es":
        "No se pudo confirmar esta acción. Conserve su trabajo local y compruebe lo guardado antes de reintentar.",
    "zh-Hans": "无法确认此操作。请保留本机内容，检查已保存状态后再重试。",
    "zh-Hant": "無法確認此操作。請保留本機內容，檢查已儲存狀態後再重試。",
    "vi":
        "Không xác nhận được thao tác. Giữ công việc trên thiết bị và kiểm tra trạng thái lưu trước khi thử lại.",
    "fil":
        "Hindi makumpirma ang gawaing ito. Panatilihin ang lokal mong gawa at suriin ang naka-save na estado bago subukan ulit.",
  },
  "A plan name is still waiting to sync. Open Plans, choose Rename, and check its sync before signing out.": {
    "es":
        "Un nombre de plan aún espera sincronizarse. Abra Planes, elija Cambiar nombre y compruebe la sincronización antes de cerrar sesión.",
    "zh-Hans": "仍有计划名称等待同步。请打开“计划”，选择“重命名”，检查同步状态后再退出登录。",
    "zh-Hant": "仍有計畫名稱等待同步。請開啟「計畫」，選擇「重新命名」，檢查同步狀態後再登出。",
    "vi":
        "Một tên kế hoạch vẫn đang chờ đồng bộ. Mở Kế hoạch, chọn Đổi tên và kiểm tra đồng bộ trước khi đăng xuất.",
    "fil":
        "May pangalan ng planong naghihintay pang mag-sync. Buksan ang Mga plano, piliin ang Palitan ang pangalan, at suriin ang sync bago mag-sign out.",
  },
  "The matching request timed out. Try again.": {
    "es": "La búsqueda agotó el tiempo de espera. Inténtelo de nuevo.",
    "zh-Hans": "匹配请求超时。请重试。",
    "zh-Hant": "配對要求逾時。請重試。",
    "vi": "Yêu cầu đối chiếu đã hết thời gian chờ. Thử lại.",
    "fil": "Nag-time out ang request sa pagtutugma. Subukang muli.",
  },
  "The case changed or the response describes another revision. Refresh the matches.": {
    "es":
        "El caso cambió o la respuesta corresponde a otra versión. Actualice las coincidencias.",
    "zh-Hans": "个案已更改或响应对应另一版本。请刷新匹配结果。",
    "zh-Hant": "個案已變更或回應對應另一版本。請重新整理配對結果。",
    "vi":
        "Hồ sơ đã thay đổi hoặc phản hồi thuộc phiên bản khác. Làm mới kết quả đối chiếu.",
    "fil":
        "Nagbago ang kaso o para sa ibang bersyon ang tugon. I-refresh ang mga tugma.",
  },
  "Sign in before requesting matches.": {
    "es": "Inicie sesión antes de buscar coincidencias.",
    "zh-Hans": "请先登录再请求匹配。",
    "zh-Hant": "請先登入再要求配對。",
    "vi": "Đăng nhập trước khi yêu cầu đối chiếu.",
    "fil": "Mag-sign in bago humiling ng mga tugma.",
  },
  "The current case is unavailable. Refresh the matches.": {
    "es": "El caso actual no está disponible. Actualice las coincidencias.",
    "zh-Hans": "当前个案不可用。请刷新匹配结果。",
    "zh-Hant": "目前個案無法使用。請重新整理配對結果。",
    "vi": "Hồ sơ hiện tại không khả dụng. Làm mới kết quả đối chiếu.",
    "fil": "Hindi available ang kasalukuyang kaso. I-refresh ang mga tugma.",
  },
  "The case changed while matching. Refresh the matches.": {
    "es": "El caso cambió durante la búsqueda. Actualice las coincidencias.",
    "zh-Hans": "匹配过程中个案已更改。请刷新匹配结果。",
    "zh-Hant": "配對過程中個案已變更。請重新整理配對結果。",
    "vi": "Hồ sơ đã thay đổi khi đối chiếu. Làm mới kết quả đối chiếu.",
    "fil": "Nagbago ang kaso habang tinutugma. I-refresh ang mga tugma.",
  },
  "The saved case changed. Refresh it before matching.": {
    "es": "El caso guardado cambió. Actualícelo antes de buscar coincidencias.",
    "zh-Hans": "已保存个案已更改。请刷新后再匹配。",
    "zh-Hant": "已儲存個案已變更。請重新整理後再配對。",
    "vi": "Hồ sơ đã lưu đã thay đổi. Làm mới trước khi đối chiếu.",
    "fil": "Nagbago ang naka-save na kaso. I-refresh bago itugma.",
  },
  "The matching service returned an unexpected response. Try again.": {
    "es":
        "El servicio de búsqueda devolvió una respuesta inesperada. Inténtelo de nuevo.",
    "zh-Hans": "匹配服务返回了意外响应。请重试。",
    "zh-Hant": "配對服務傳回了非預期回應。請重試。",
    "vi": "Dịch vụ đối chiếu trả về phản hồi không mong đợi. Thử lại.",
    "fil":
        "Nagbalik ang serbisyo ng pagtutugma ng hindi inaasahang tugon. Subukang muli.",
  },
  "Unable to reach the matching service. Try again when connected.": {
    "es":
        "No se pudo conectar con el servicio de búsqueda. Reintente cuando tenga conexión.",
    "zh-Hans": "无法连接匹配服务。请联网后重试。",
    "zh-Hant": "無法連線配對服務。請連線後重試。",
    "vi": "Không kết nối được dịch vụ đối chiếu. Thử lại khi có kết nối.",
    "fil":
        "Hindi makakonekta sa serbisyo ng pagtutugma. Subukang muli kapag nakakonekta na.",
  },
  "The matching service response was too large. Try again.": {
    "es":
        "La respuesta del servicio de búsqueda era demasiado grande. Inténtelo de nuevo.",
    "zh-Hans": "匹配服务响应过大。请重试。",
    "zh-Hant": "配對服務回應過大。請重試。",
    "vi": "Phản hồi dịch vụ đối chiếu quá lớn. Thử lại.",
    "fil":
        "Masyadong malaki ang tugon ng serbisyo ng pagtutugma. Subukang muli.",
  },
  "The matching service destination changed. Check the service configuration.": {
    "es":
        "El destino del servicio de búsqueda cambió. Compruebe su configuración.",
    "zh-Hans": "匹配服务地址已更改。请检查匹配服务配置。",
    "zh-Hant": "配對服務位址已變更。請檢查配對服務設定。",
    "vi":
        "Địa chỉ dịch vụ đối chiếu đã thay đổi. Kiểm tra cấu hình dịch vụ đối chiếu.",
    "fil":
        "Nagbago ang destinasyon ng serbisyo ng pagtutugma. Suriin ang configuration nito.",
  },
  "The matching service could not read the request format.": {
    "es": "El servicio de búsqueda no pudo leer el formato de la solicitud.",
    "zh-Hans": "匹配服务无法读取请求格式。",
    "zh-Hant": "配對服務無法讀取要求格式。",
    "vi": "Dịch vụ đối chiếu không đọc được định dạng yêu cầu.",
    "fil": "Hindi mabasa ng serbisyo ng pagtutugma ang format ng request.",
  },
  "The matching service could not accept this request method.": {
    "es": "El servicio de búsqueda no pudo aceptar este método de solicitud.",
    "zh-Hans": "匹配服务无法接受此请求方法。",
    "zh-Hant": "配對服務無法接受此要求方法。",
    "vi": "Dịch vụ đối chiếu không chấp nhận phương thức yêu cầu này.",
    "fil":
        "Hindi matanggap ng serbisyo ng pagtutugma ang pamamaraang ito ng request.",
  },
  "The matching service could not finish the request. Try again.": {
    "es":
        "El servicio de búsqueda no pudo completar la solicitud. Inténtelo de nuevo.",
    "zh-Hans": "匹配服务未能完成请求。请重试。",
    "zh-Hant": "配對服務未能完成要求。請重試。",
    "vi": "Dịch vụ đối chiếu không hoàn tất được yêu cầu. Thử lại.",
    "fil":
        "Hindi matapos ng serbisyo ng pagtutugma ang request. Subukang muli.",
  },
  "The matching service is temporarily unavailable. Try again later.": {
    "es":
        "El servicio de búsqueda no está disponible temporalmente. Inténtelo más tarde.",
    "zh-Hans": "匹配服务暂时不可用。请稍后重试。",
    "zh-Hant": "配對服務暫時無法使用。請稍後重試。",
    "vi": "Dịch vụ đối chiếu tạm thời không khả dụng. Thử lại sau.",
    "fil":
        "Pansamantalang hindi available ang serbisyo ng pagtutugma. Subukang muli mamaya.",
  },
  "The matching request was invalid. Review the case and try again.": {
    "es": "La solicitud no era válida. Revise el caso e inténtelo de nuevo.",
    "zh-Hans": "请求无效。请核对个案后重试。",
    "zh-Hant": "要求無效。請核對個案後重試。",
    "vi": "Yêu cầu không hợp lệ. Kiểm tra hồ sơ và thử lại.",
    "fil": "Hindi wasto ang request. Suriin ang kaso at subukang muli.",
  },
  "The matching request was too large.": {
    "es": "La solicitud era demasiado grande.",
    "zh-Hans": "请求过大。",
    "zh-Hant": "要求過大。",
    "vi": "Yêu cầu quá lớn.",
    "fil": "Masyadong malaki ang request.",
  },
  "The matching endpoint was not found. Check the service configuration.": {
    "es":
        "No se encontró el punto de acceso. Compruebe la configuración del servicio.",
    "zh-Hans": "找不到服务端点。请检查服务配置。",
    "zh-Hant": "找不到服務端點。請檢查服務設定。",
    "vi": "Không tìm thấy điểm cuối. Kiểm tra cấu hình dịch vụ.",
    "fil": "Hindi mahanap ang endpoint. Suriin ang configuration ng serbisyo.",
  },
  "Sign-out could not be confirmed. Try again, or unlock your phone and restart the app.": {
    "es":
        "No se pudo confirmar el cierre de sesión. Inténtelo de nuevo o desbloquee el teléfono y reinicie la aplicación.",
    "zh-Hans": "无法确认是否已退出登录。请重试，或解锁手机后重新启动应用。",
    "zh-Hant": "無法確認是否已登出。請重試，或解鎖手機後重新啟動應用程式。",
    "vi":
        "Không thể xác nhận việc đăng xuất. Hãy thử lại hoặc mở khóa điện thoại rồi khởi động lại ứng dụng.",
    "fil":
        "Hindi makumpirma ang pag-sign out. Subukang muli, o i-unlock ang telepono at i-restart ang app.",
  },
  "Restored on this device. Check saved state before continuing.": {
    "es":
        "Restaurado en este dispositivo. Compruebe el estado guardado antes de continuar.",
    "zh-Hans": "已在此设备上恢复。继续前请检查保存状态。",
    "zh-Hant": "已在此裝置上復原。繼續前請檢查儲存狀態。",
    "vi":
        "Đã khôi phục trên thiết bị này. Kiểm tra trạng thái đã lưu trước khi tiếp tục.",
    "fil":
        "Naibalik sa device na ito. Suriin ang naka-save na kalagayan bago magpatuloy.",
  },
  "Restored on this device. Its custom name could not be loaded.": {
    "es":
        "Restaurado en este dispositivo. No se pudo cargar su nombre personalizado.",
    "zh-Hans": "已在此设备上恢复。无法加载其自定义名称。",
    "zh-Hant": "已在此裝置上復原。無法載入其自訂名稱。",
    "vi": "Đã khôi phục trên thiết bị này. Không tải được tên tùy chỉnh.",
    "fil":
        "Naibalik sa device na ito. Hindi ma-load ang pasadyang pangalan nito.",
  },
  "This plan’s custom name could not be loaded.": {
    "es": "No se pudo cargar el nombre personalizado de este plan.",
    "zh-Hans": "无法加载此计划的自定义名称。",
    "zh-Hant": "無法載入此計畫的自訂名稱。",
    "vi": "Không tải được tên tùy chỉnh của kế hoạch này.",
    "fil": "Hindi ma-load ang pasadyang pangalan ng planong ito.",
  },
  "The saved case changed. Compare it with your local edits before saving.": {
    "es":
        "El caso guardado cambió. Compárelo con sus cambios locales antes de guardar.",
    "zh-Hans": "已保存的个案发生变化。保存前请将其与本地修改进行比较。",
    "zh-Hant": "已儲存的個案發生變更。儲存前請將其與本機修改進行比較。",
    "vi":
        "Hồ sơ đã lưu đã thay đổi. So sánh với chỉnh sửa trên thiết bị trước khi lưu.",
    "fil":
        "Nagbago ang naka-save na kaso. Ihambing ito sa mga lokal mong pagbabago bago mag-save.",
  },
  "Saved on this device; not yet saved online.": {
    "es": "Guardado en este dispositivo; aún no está guardado en línea.",
    "zh-Hans": "已保存在此设备上，尚未保存到线上。",
    "zh-Hant": "已儲存在此裝置上，尚未儲存至線上。",
    "vi": "Đã lưu trên thiết bị này; chưa lưu trực tuyến.",
    "fil": "Na-save sa device na ito; hindi pa naka-save online.",
  },
  "The latest changes were not saved on this device. Keep this screen open and retry.": {
    "es":
        "Los últimos cambios no se guardaron en este dispositivo. Mantenga esta pantalla abierta e inténtelo de nuevo.",
    "zh-Hans": "最新修改未保存在此设备上。请保持此页面打开并重试。",
    "zh-Hant": "最新修改未儲存在此裝置上。請保持此頁面開啟並重試。",
    "vi":
        "Các thay đổi mới nhất chưa được lưu trên thiết bị này. Giữ màn hình này mở rồi thử lại.",
    "fil":
        "Hindi na-save sa device na ito ang mga pinakabagong pagbabago. Panatilihing bukas ang screen na ito at subukang muli.",
  },
  "Saved on this device. Check the unresolved saved-state result before another online save.": {
    "es":
        "Guardado en este dispositivo. Revise el resultado de guardado pendiente de resolver antes de volver a guardar en línea.",
    "zh-Hans": "已保存在此设备上。再次保存到线上前，请检查尚未确认的保存结果。",
    "zh-Hant": "已儲存在此裝置上。再次儲存至線上前，請檢查尚未確認的儲存結果。",
    "vi":
        "Đã lưu trên thiết bị này. Kiểm tra kết quả lưu chưa được giải quyết trước khi lưu trực tuyến lần nữa.",
    "fil":
        "Na-save sa device na ito. Suriin ang hindi pa nalilinaw na resulta ng pag-save bago mag-save muli online.",
  },
  "Earlier changes saved online. Newer edits are kept on this device.": {
    "es":
        "Los cambios anteriores se guardaron en línea. Los más recientes se conservan en este dispositivo.",
    "zh-Hans": "较早的修改已保存到线上。较新的修改保留在此设备上。",
    "zh-Hant": "較早的修改已儲存至線上。較新的修改保留在此裝置上。",
    "vi":
        "Các thay đổi trước đã lưu trực tuyến. Chỉnh sửa mới hơn được giữ trên thiết bị này.",
    "fil":
        "Na-save online ang mga naunang pagbabago. Nananatili sa device na ito ang mas bagong mga pagbabago.",
  },
  "Saved online.": {
    "es": "Guardado en línea.",
    "zh-Hans": "已保存到线上。",
    "zh-Hant": "已儲存至線上。",
    "vi": "Đã lưu trực tuyến.",
    "fil": "Na-save online.",
  },
  "The save could not be confirmed. Check saved state before trying again.": {
    "es":
        "No se pudo confirmar el guardado. Compruebe el estado guardado antes de volver a intentarlo.",
    "zh-Hans": "无法确认保存是否成功。重试前请检查保存状态。",
    "zh-Hant": "無法確認儲存是否成功。重試前請檢查儲存狀態。",
    "vi":
        "Không thể xác nhận việc lưu. Kiểm tra trạng thái đã lưu trước khi thử lại.",
    "fil":
        "Hindi makumpirma ang pag-save. Suriin ang naka-save na kalagayan bago subukang muli.",
  },
  "Your changes are saved online.": {
    "es": "Sus cambios están guardados en línea.",
    "zh-Hans": "您的修改已保存到线上。",
    "zh-Hant": "您的修改已儲存至線上。",
    "vi": "Các thay đổi của bạn đã được lưu trực tuyến.",
    "fil": "Naka-save online ang iyong mga pagbabago.",
  },
  "The server and this device differ. Choose which version to keep.": {
    "es":
        "El servidor y este dispositivo tienen versiones distintas. Elija cuál conservar.",
    "zh-Hans": "服务器与此设备的版本不同。请选择要保留的版本。",
    "zh-Hant": "伺服器與此裝置的版本不同。請選擇要保留的版本。",
    "vi":
        "Máy chủ và thiết bị này có dữ liệu khác nhau. Chọn phiên bản muốn giữ.",
    "fil":
        "Magkaiba ang bersyon sa server at sa device na ito. Piliin kung alin ang pananatilihin.",
  },
  "No saved case was found. You can retry saving this same draft.": {
    "es":
        "No se encontró ningún caso guardado. Puede volver a intentar guardar este mismo borrador.",
    "zh-Hans": "未找到已保存的个案。您可以重试保存这份草稿。",
    "zh-Hant": "未找到已儲存的個案。您可以重試儲存這份草稿。",
    "vi":
        "Không tìm thấy hồ sơ đã lưu. Bạn có thể thử lưu lại cùng bản nháp này.",
    "fil":
        "Walang nakitang naka-save na kaso. Maaari mong subukang i-save muli ang parehong draft na ito.",
  },
  "Local edits retained. Review and save them explicitly.": {
    "es":
        "Se conservaron los cambios locales. Revíselos y guárdelos mediante la acción de guardar.",
    "zh-Hans": "已保留本地修改。请审核后主动保存。",
    "zh-Hant": "已保留本機修改。請審查後主動儲存。",
    "vi": "Đã giữ chỉnh sửa trên thiết bị. Xem lại rồi chủ động lưu.",
    "fil":
        "Napanatili ang mga lokal na pagbabago. Suriin ang mga ito at piliing i-save.",
  },
  "Using the saved version.": {
    "es": "Se está usando la versión guardada.",
    "zh-Hans": "正在使用已保存的版本。",
    "zh-Hant": "正在使用已儲存的版本。",
    "vi": "Đang dùng phiên bản đã lưu.",
    "fil": "Ginagamit ang naka-save na bersyon.",
  },
  "A server operation completed while local edits changed. Review both versions.": {
    "es":
        "Se completó una operación del servidor mientras cambiaban los datos locales. Revise ambas versiones.",
    "zh-Hans": "服务器操作完成时，本地修改已发生变化。请检查两个版本。",
    "zh-Hant": "伺服器操作完成時，本機修改已發生變更。請檢查兩個版本。",
    "vi":
        "Một thao tác trên máy chủ hoàn tất trong khi chỉnh sửa trên thiết bị thay đổi. Xem lại cả hai phiên bản.",
    "fil":
        "Natapos ang isang operasyon sa server habang nagbabago ang mga lokal na edit. Suriin ang dalawang bersyon.",
  },
  "The private local save could not finish.": {
    "es": "No se pudo completar el guardado privado en este dispositivo.",
    "zh-Hans": "无法完成私密本地保存。",
    "zh-Hant": "無法完成私密本機儲存。",
    "vi": "Không thể hoàn tất việc lưu riêng tư trên thiết bị.",
    "fil": "Hindi matapos ang pribadong pag-save sa device.",
  },
  "A photo is saved, but we cannot prove it is your upload. Review it before choosing which version to keep.": {
    "es":
        "Hay una foto guardada, pero no podemos confirmar que sea la que usted subió. Revísela antes de elegir qué versión conservar.",
    "zh-Hans": "有一张照片已保存，但无法确认是否为您上传的照片。选择保留哪个版本前，请先查看。",
    "zh-Hant": "有一張照片已儲存，但無法確認是否為您上傳的照片。選擇保留哪個版本前，請先查看。",
    "vi":
        "Có ảnh đã lưu nhưng chưa thể xác nhận đó là ảnh bạn tải lên. Xem lại trước khi chọn phiên bản muốn giữ.",
    "fil":
        "May naka-save na larawan, pero hindi namin mapatunayan na iyon ang na-upload mo. Suriin ito bago pumili ng bersyong pananatilihin.",
  },
  "The saved state could not be recorded privately on this device. Free device space, then check again.": {
    "es":
        "No se pudo registrar de forma privada el estado guardado en este dispositivo. Libere espacio y vuelva a comprobarlo.",
    "zh-Hans": "无法在此设备上私密记录保存状态。请释放设备空间，然后重新检查。",
    "zh-Hant": "無法在此裝置上私密記錄儲存狀態。請釋放裝置空間，然後重新檢查。",
    "vi":
        "Không thể ghi lại trạng thái đã lưu một cách riêng tư trên thiết bị này. Giải phóng dung lượng rồi kiểm tra lại.",
    "fil":
        "Hindi maitala nang pribado sa device na ito ang naka-save na kalagayan. Magbakante ng espasyo, pagkatapos ay suriin muli.",
  },
  "The draft could not be prepared accurately. Review the text, measurements and images. The current PDF does not support all characters or layouts. Your saved information is kept; preserve the original spelling.": {
    "es":
        "No se pudo preparar el borrador con precisión. Revise el texto, las medidas y las imágenes. El PDF actual no admite todos los caracteres ni todos los diseños. Su información guardada se conserva; mantenga la escritura original.",
    "zh-Hans":
        "无法准确生成草稿。请检查文字、测量值和图片。当前 PDF 并不支持所有字符或版式。您的已保存信息仍保留，请保留原来的文字写法。",
    "zh-Hant":
        "無法準確產生草稿。請檢查文字、測量值和圖片。目前的 PDF 並不支援所有字元或版面。您的已儲存資訊仍保留，請保留原來的文字寫法。",
    "vi":
        "Không thể tạo bản nháp chính xác. Xem lại văn bản, số đo và hình ảnh. PDF hiện tại không hỗ trợ mọi ký tự hoặc bố cục. Thông tin đã lưu được giữ nguyên; hãy giữ cách viết ban đầu.",
    "fil":
        "Hindi magawang ihanda nang tumpak ang draft. Suriin ang teksto, mga sukat at mga larawan. Hindi sinusuportahan ng kasalukuyang PDF ang lahat ng character o layout. Nananatili ang naka-save mong impormasyon; panatilihin ang orihinal na baybay.",
  },
};
