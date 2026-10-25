const trackingTranslations = <String, Map<String, String>>{
  'Loading tasks and program progress': {
    'es': 'Cargando tareas y progreso de programas',
    'zh-Hans': '正在加载任务和项目进度',
    'zh-Hant': '正在載入任務和計畫進度',
    'vi': 'Đang tải công việc và tiến độ chương trình',
    'fil': 'Nilo-load ang mga gawain at progreso ng programa',
  },
  'Tasks are unavailable on this service. Try again after the service is updated.': {
    'es':
        'Las tareas no están disponibles en este servicio. Inténtelo de nuevo cuando se actualice el servicio.',
    'zh-Hans': '此服务暂不提供任务功能。请在服务更新后重试。',
    'zh-Hant': '此服務暫不提供任務功能。請在服務更新後重試。',
    'vi':
        'Dịch vụ này chưa có công việc. Hãy thử lại sau khi dịch vụ được cập nhật.',
    'fil':
        'Hindi available ang mga gawain sa serbisyong ito. Subukang muli kapag na-update ang serbisyo.',
  },
  'Tasks are temporarily unavailable. Try again later.': {
    'es': 'Las tareas no están disponibles temporalmente. Inténtelo más tarde.',
    'zh-Hans': '任务暂时不可用。请稍后重试。',
    'zh-Hant': '任務暫時無法使用。請稍後重試。',
    'vi': 'Công việc tạm thời không khả dụng. Hãy thử lại sau.',
    'fil':
        'Pansamantalang hindi available ang mga gawain. Subukang muli mamaya.',
  },
  'Cannot connect to load tasks. Check your connection and try again.': {
    'es':
        'No se puede conectar para cargar las tareas. Revise la conexión e inténtelo de nuevo.',
    'zh-Hans': '无法连接以加载任务。请检查网络连接后重试。',
    'zh-Hant': '無法連線以載入任務。請檢查網路連線後重試。',
    'vi': 'Không thể kết nối để tải công việc. Kiểm tra kết nối và thử lại.',
    'fil':
        'Hindi makakonekta para i-load ang mga gawain. Suriin ang koneksyon at subukang muli.',
  },
  'Cannot connect. Showing the last saved tasks; refresh before making changes.': {
    'es':
        'No se puede conectar. Se muestran las últimas tareas guardadas; actualice antes de hacer cambios.',
    'zh-Hans': '无法连接。正在显示上次保存的任务；更改前请刷新。',
    'zh-Hant': '無法連線。正在顯示上次儲存的任務；變更前請重新整理。',
    'vi':
        'Không thể kết nối. Đang hiển thị công việc đã lưu gần nhất; hãy làm mới trước khi thay đổi.',
    'fil':
        'Hindi makakonekta. Ipinapakita ang huling na-save na mga gawain; i-refresh bago baguhin.',
  },
  'Saved copy. Refresh before changing tasks.': {
    'es': 'Copia guardada. Actualice antes de cambiar las tareas.',
    'zh-Hans': '已保存的副本。更改任务前请刷新。',
    'zh-Hant': '已儲存的副本。變更任務前請重新整理。',
    'vi': 'Bản đã lưu. Hãy làm mới trước khi thay đổi công việc.',
    'fil': 'Na-save na kopya. I-refresh bago baguhin ang mga gawain.',
  },
  'Reopen task': {
    'es': 'Reabrir tarea',
    'zh-Hans': '重新打开任务',
    'zh-Hant': '重新開啟任務',
    'vi': 'Mở lại công việc',
    'fil': 'Buksan muli ang gawain',
  },
  "Program progress changed. Refresh and review your pending change.": {
    "es": "El progreso cambió. Actualice y revise su cambio pendiente.",
    "zh-Hans": "项目进度已更改。请刷新并审核待确认更改。",
    "zh-Hant": "計畫進度已變更。請更新並審核待確認變更。",
    "vi": "Tiến độ đã đổi. Cập nhật và xem thay đổi đang chờ.",
    "fil":
        "Nagbago ang progreso. I-refresh at suriin ang nakabinbing pagbabago.",
  },
  "This task changed. Refresh and review your pending change.": {
    "es": "Esta tarea cambió. Actualice y revise su cambio pendiente.",
    "zh-Hans": "此任务已更改。请刷新并审核待确认更改。",
    "zh-Hant": "此任務已變更。請更新並審核待確認變更。",
    "vi": "Công việc đã đổi. Cập nhật và xem thay đổi đang chờ.",
    "fil": "Nagbago ang gawain. I-refresh at suriin ang nakabinbing pagbabago.",
  },
  "This save identifier was already used. Review saved progress before discarding the pending change.": {
    "es":
        "El identificador ya se usó. Revise el progreso guardado antes de descartar el cambio pendiente.",
    "zh-Hans": "此保存标识已被使用。放弃待确认更改前请审核已保存的进度。",
    "zh-Hant": "此儲存識別碼已被使用。放棄待確認變更前請審核已儲存的進度。",
    "vi":
        "Mã lưu này đã được dùng. Xem tiến độ đã lưu trước khi bỏ thay đổi đang chờ.",
    "fil":
        "Nagamit na ang ID ng pag-save. Suriin muna ang naka-save na progreso bago itapon ang nakabinbing pagbabago.",
  },
  "The tracking limit has been reached. Existing tasks and history are retained.": {
    "es":
        "Se alcanzó el límite de seguimiento. Se conservan las tareas y el historial.",
    "zh-Hans": "已达到跟踪上限。现有任务和历史记录仍保留。",
    "zh-Hant": "已達追蹤上限。現有任務和歷史紀錄仍保留。",
    "vi":
        "Đã đạt giới hạn theo dõi. Công việc và lịch sử hiện có vẫn được giữ.",
    "fil": "Naabot na ang limitasyon. Napanatili ang mga gawain at kasaysayan.",
  },
  "This save could not be confirmed. Retry the same pending change to avoid duplicates.": {
    "es":
        "No se pudo confirmar el guardado. Reintente el mismo cambio pendiente para evitar duplicados.",
    "zh-Hans": "无法确认此次保存。请重试同一待确认更改以避免重复。",
    "zh-Hant": "無法確認此次儲存。請重試同一待確認變更以避免重複。",
    "vi":
        "Không thể xác nhận lần lưu. Thử lại cùng thay đổi để tránh trùng lặp.",
    "fil":
        "Hindi makumpirma ang pag-save. Subukang muli ang parehong pagbabago upang maiwasan ang pagdodoble.",
  },

  "My next steps": {
    "es": "Mis próximos pasos",
    "zh-Hans": "我的后续步骤",
    "zh-Hant": "我的後續步驟",
    "vi": "Các bước tiếp theo của tôi",
    "fil": "Mga susunod kong hakbang",
  },
  "Program progress": {
    "es": "Progreso de programas",
    "zh-Hans": "项目进度",
    "zh-Hant": "計畫進度",
    "vi": "Tiến độ chương trình",
    "fil": "Progreso ng programa",
  },
  "Program progress, tasks, and device reminders": {
    "es": "Progreso, tareas y recordatorios del dispositivo",
    "zh-Hans": "项目进度、任务和设备提醒",
    "zh-Hant": "計畫進度、任務和裝置提醒",
    "vi": "Tiến độ, công việc và nhắc nhở trên thiết bị",
    "fil": "Progreso, mga gawain, at paalala sa device",
  },
  "Programs": {
    "es": "Programas",
    "zh-Hans": "项目",
    "zh-Hant": "計畫",
    "vi": "Chương trình",
    "fil": "Mga programa",
  },
  "Tasks": {
    "es": "Tareas",
    "zh-Hans": "任务",
    "zh-Hant": "任務",
    "vi": "Công việc",
    "fil": "Mga gawain",
  },
  "Track program": {
    "es": "Seguir programa",
    "zh-Hans": "跟踪项目",
    "zh-Hant": "追蹤計畫",
    "vi": "Theo dõi chương trình",
    "fil": "Subaybayan ang programa",
  },
  "Add next step": {
    "es": "Añadir próximo paso",
    "zh-Hans": "添加后续步骤",
    "zh-Hant": "新增後續步驟",
    "vi": "Thêm bước tiếp theo",
    "fil": "Magdagdag ng susunod na hakbang",
  },
  "Next step": {
    "es": "Próximo paso",
    "zh-Hans": "后续步骤",
    "zh-Hant": "後續步驟",
    "vi": "Bước tiếp theo",
    "fil": "Susunod na hakbang",
  },
  "Edit task": {
    "es": "Editar tarea",
    "zh-Hans": "编辑任务",
    "zh-Hant": "編輯任務",
    "vi": "Sửa công việc",
    "fil": "I-edit ang gawain",
  },
  "Save task": {
    "es": "Guardar tarea",
    "zh-Hans": "保存任务",
    "zh-Hant": "儲存任務",
    "vi": "Lưu công việc",
    "fil": "I-save ang gawain",
  },
  "Complete task": {
    "es": "Completar tarea",
    "zh-Hans": "完成任务",
    "zh-Hant": "完成任務",
    "vi": "Hoàn thành công việc",
    "fil": "Tapusin ang gawain",
  },
  "Task type": {
    "es": "Tipo de tarea",
    "zh-Hans": "任务类型",
    "zh-Hant": "任務類型",
    "vi": "Loại công việc",
    "fil": "Uri ng gawain",
  },
  "Task status": {
    "es": "Estado de tarea",
    "zh-Hans": "任务状态",
    "zh-Hant": "任務狀態",
    "vi": "Trạng thái công việc",
    "fil": "Katayuan ng gawain",
  },
  "Pending": {
    "es": "Pendiente",
    "zh-Hans": "待处理",
    "zh-Hant": "待處理",
    "vi": "Đang chờ",
    "fil": "Nakabinbin",
  },
  "In progress": {
    "es": "En curso",
    "zh-Hans": "进行中",
    "zh-Hant": "進行中",
    "vi": "Đang thực hiện",
    "fil": "Kasalukuyang ginagawa",
  },
  "Blocked": {
    "es": "Bloqueada",
    "zh-Hans": "受阻",
    "zh-Hant": "受阻",
    "vi": "Bị cản trở",
    "fil": "May hadlang",
  },
  "Completed": {
    "es": "Completada",
    "zh-Hans": "已完成",
    "zh-Hant": "已完成",
    "vi": "Đã hoàn thành",
    "fil": "Tapos na",
  },
  "Cancelled": {
    "es": "Cancelada",
    "zh-Hans": "已取消",
    "zh-Hant": "已取消",
    "vi": "Đã hủy",
    "fil": "Kinansela",
  },
  "Profile completion": {
    "es": "Completar perfil",
    "zh-Hans": "完善个人资料",
    "zh-Hant": "完善個人資料",
    "vi": "Hoàn tất hồ sơ",
    "fil": "Pagkumpleto ng profile",
  },
  "Room review": {
    "es": "Revisión de habitación",
    "zh-Hans": "房间检查",
    "zh-Hant": "房間檢查",
    "vi": "Xem xét phòng",
    "fil": "Pagsusuri ng silid",
  },
  "Documents": {
    "es": "Documentos",
    "zh-Hans": "文件",
    "zh-Hant": "文件",
    "vi": "Giấy tờ",
    "fil": "Mga dokumento",
  },
  "Contact a provider": {
    "es": "Contactar a un proveedor",
    "zh-Hans": "联系服务机构",
    "zh-Hant": "聯絡服務機構",
    "vi": "Liên hệ nhà cung cấp",
    "fil": "Makipag-ugnayan sa tagapagbigay",
  },
  "Draft review": {
    "es": "Revisión del borrador",
    "zh-Hans": "草稿审核",
    "zh-Hant": "草稿審核",
    "vi": "Xem xét bản nháp",
    "fil": "Pagsusuri ng draft",
  },
  "Follow up": {
    "es": "Dar seguimiento",
    "zh-Hans": "跟进",
    "zh-Hant": "跟進",
    "vi": "Theo dõi tiếp",
    "fil": "Mag-follow up",
  },
  "Unassigned": {
    "es": "Sin asignar",
    "zh-Hans": "未分配",
    "zh-Hant": "未指派",
    "vi": "Chưa phân công",
    "fil": "Walang nakatalaga",
  },
  "Responsible person (optional)": {
    "es": "Persona responsable (opcional)",
    "zh-Hans": "负责人（可选）",
    "zh-Hant": "負責人（選填）",
    "vi": "Người phụ trách (tùy chọn)",
    "fil": "Taong responsable (opsyonal)",
  },
  "Responsible person: {person}": {
    "es": "Persona responsable: {person}",
    "zh-Hans": "负责人：{person}",
    "zh-Hant": "負責人：{person}",
    "vi": "Người phụ trách: {person}",
    "fil": "Taong responsable: {person}",
  },
  "Target date (YYYY-MM-DD, optional)": {
    "es": "Fecha objetivo (AAAA-MM-DD, opcional)",
    "zh-Hans": "目标日期（YYYY-MM-DD，可选）",
    "zh-Hant": "目標日期（YYYY-MM-DD，選填）",
    "vi": "Ngày dự kiến (YYYY-MM-DD, tùy chọn)",
    "fil": "Target na petsa (YYYY-MM-DD, opsyonal)",
  },
  "Target date: {date}": {
    "es": "Fecha objetivo: {date}",
    "zh-Hans": "目标日期：{date}",
    "zh-Hant": "目標日期：{date}",
    "vi": "Ngày dự kiến: {date}",
    "fil": "Target na petsa: {date}",
  },
  "Overdue target: {date}": {
    "es": "Objetivo vencido: {date}",
    "zh-Hans": "已过目标日期：{date}",
    "zh-Hant": "已過目標日期：{date}",
    "vi": "Quá ngày dự kiến: {date}",
    "fil": "Lampas sa target: {date}",
  },
  "No target date": {
    "es": "Sin fecha objetivo",
    "zh-Hans": "无目标日期",
    "zh-Hant": "無目標日期",
    "vi": "Chưa có ngày dự kiến",
    "fil": "Walang target na petsa",
  },
  "Program (optional)": {
    "es": "Programa (opcional)",
    "zh-Hans": "项目（可选）",
    "zh-Hant": "計畫（選填）",
    "vi": "Chương trình (tùy chọn)",
    "fil": "Programa (opsyonal)",
  },
  "Whole plan": {
    "es": "Todo el plan",
    "zh-Hans": "整个计划",
    "zh-Hant": "整份計畫",
    "vi": "Toàn bộ kế hoạch",
    "fil": "Buong plano",
  },
  "Related concern (optional)": {
    "es": "Problema relacionado (opcional)",
    "zh-Hans": "相关问题（可选）",
    "zh-Hant": "相關問題（選填）",
    "vi": "Vấn đề liên quan (tùy chọn)",
    "fil": "Kaugnay na alalahanin (opsyonal)",
  },
  "Plan changed. Review this task.": {
    "es": "El plan cambió. Revise esta tarea.",
    "zh-Hans": "计划已更改。请审核此任务。",
    "zh-Hant": "計畫已變更。請審核此任務。",
    "vi": "Kế hoạch đã đổi. Hãy xem lại công việc này.",
    "fil": "Nagbago ang plano. Suriin ang gawaing ito.",
  },
  "I reviewed this task against the current plan.": {
    "es": "Revisé esta tarea con el plan actual.",
    "zh-Hans": "我已根据当前计划审核此任务。",
    "zh-Hant": "我已依目前計畫審核此任務。",
    "vi": "Tôi đã xem lại công việc theo kế hoạch hiện tại.",
    "fil": "Sinuri ko ang gawaing ito ayon sa kasalukuyang plano.",
  },
  "Review this task against the current plan before saving.": {
    "es": "Revise esta tarea con el plan actual antes de guardarla.",
    "zh-Hans": "保存前请根据当前计划审核此任务。",
    "zh-Hant": "儲存前請依目前計畫審核此任務。",
    "vi": "Xem lại công việc theo kế hoạch hiện tại trước khi lưu.",
    "fil": "Suriin ang gawain ayon sa kasalukuyang plano bago i-save.",
  },
  "Enter a next step.": {
    "es": "Ingrese un próximo paso.",
    "zh-Hans": "请输入后续步骤。",
    "zh-Hant": "請輸入後續步驟。",
    "vi": "Nhập bước tiếp theo.",
    "fil": "Maglagay ng susunod na hakbang.",
  },
  "Use a valid date: YYYY-MM-DD.": {
    "es": "Use una fecha válida: AAAA-MM-DD.",
    "zh-Hans": "请使用有效日期：YYYY-MM-DD。",
    "zh-Hant": "請使用有效日期：YYYY-MM-DD。",
    "vi": "Dùng ngày hợp lệ: YYYY-MM-DD.",
    "fil": "Gumamit ng wastong petsa: YYYY-MM-DD.",
  },
  "Not started / no update recorded": {
    "es": "Sin iniciar / sin actualización registrada",
    "zh-Hans": "尚未开始／未记录更新",
    "zh-Hant": "尚未開始／未記錄更新",
    "vi": "Chưa bắt đầu / chưa có cập nhật",
    "fil": "Hindi pa nasimulan / walang naitalang update",
  },
  "Reported {date} by {person}": {
    "es": "Reportado el {date} por {person}",
    "zh-Hans": "{person} 于 {date} 报告",
    "zh-Hant": "{person} 於 {date} 回報",
    "vi": "{person} báo cáo lúc {date}",
    "fil": "Iniulat noong {date} ni {person}",
  },
  "Reported by: {person}": {
    "es": "Reportado por: {person}",
    "zh-Hans": "报告人：{person}",
    "zh-Hant": "回報人：{person}",
    "vi": "Người báo cáo: {person}",
    "fil": "Iniulat ni: {person}",
  },
  "Legacy report; reporter not recorded": {
    "es": "Informe anterior; autor no registrado",
    "zh-Hans": "旧记录；未记录报告人",
    "zh-Hant": "舊紀錄；未記錄回報人",
    "vi": "Báo cáo cũ; chưa ghi người báo cáo",
    "fil": "Lumang ulat; walang naitalang nag-ulat",
  },
  "Open next steps: {count}": {
    "es": "Próximos pasos pendientes: {count}",
    "zh-Hans": "未完成步骤：{count}",
    "zh-Hant": "未完成步驟：{count}",
    "vi": "Bước chưa hoàn tất: {count}",
    "fil": "Mga bukas na hakbang: {count}",
  },
  "Next: {task} · {date}": {
    "es": "Siguiente: {task} · {date}",
    "zh-Hans": "下一步：{task} · {date}",
    "zh-Hant": "下一步：{task} · {date}",
    "vi": "Tiếp theo: {task} · {date}",
    "fil": "Susunod: {task} · {date}",
  },
  "Report program status": {
    "es": "Reportar estado del programa",
    "zh-Hans": "报告项目状态",
    "zh-Hant": "回報計畫狀態",
    "vi": "Báo cáo trạng thái chương trình",
    "fil": "Iulat ang katayuan ng programa",
  },
  "Is this old next action still needed?": {
    "es": "¿Todavía necesita esta acción anterior?",
    "zh-Hans": "仍需执行此旧后续行动吗？",
    "zh-Hant": "仍需執行此舊後續行動嗎？",
    "vi": "Bước cũ này còn cần thiết không?",
    "fil": "Kailangan pa ba ang lumang hakbang na ito?",
  },
  "Review and add task": {
    "es": "Revisar y añadir tarea",
    "zh-Hans": "审核并添加任务",
    "zh-Hant": "審核並新增任務",
    "vi": "Xem lại và thêm công việc",
    "fil": "Suriin at idagdag ang gawain",
  },
  "No longer needed": {
    "es": "Ya no se necesita",
    "zh-Hans": "不再需要",
    "zh-Hant": "不再需要",
    "vi": "Không còn cần thiết",
    "fil": "Hindi na kailangan",
  },
  "Device reminder": {
    "es": "Recordatorio del dispositivo",
    "zh-Hans": "设备提醒",
    "zh-Hant": "裝置提醒",
    "vi": "Nhắc nhở trên thiết bị",
    "fil": "Paalala sa device",
  },
  "Snooze reminder": {
    "es": "Posponer recordatorio",
    "zh-Hans": "推迟提醒",
    "zh-Hant": "延後提醒",
    "vi": "Hoãn nhắc nhở",
    "fil": "Ipagpaliban ang paalala",
  },
  "Disable reminder": {
    "es": "Desactivar recordatorio",
    "zh-Hans": "关闭提醒",
    "zh-Hant": "關閉提醒",
    "vi": "Tắt nhắc nhở",
    "fil": "I-off ang paalala",
  },
  "Enable reminder": {
    "es": "Activar recordatorio",
    "zh-Hans": "启用提醒",
    "zh-Hant": "啟用提醒",
    "vi": "Bật nhắc nhở",
    "fil": "I-on ang paalala",
  },
  "Reminder date (YYYY-MM-DD)": {
    "es": "Fecha del recordatorio (AAAA-MM-DD)",
    "zh-Hans": "提醒日期（YYYY-MM-DD）",
    "zh-Hant": "提醒日期（YYYY-MM-DD）",
    "vi": "Ngày nhắc (YYYY-MM-DD)",
    "fil": "Petsa ng paalala (YYYY-MM-DD)",
  },
  "Reminder time (HH:MM)": {
    "es": "Hora del recordatorio (HH:MM)",
    "zh-Hans": "提醒时间（HH:MM）",
    "zh-Hant": "提醒時間（HH:MM）",
    "vi": "Giờ nhắc (HH:MM)",
    "fil": "Oras ng paalala (HH:MM)",
  },
  "Time zone (IANA)": {
    "es": "Zona horaria (IANA)",
    "zh-Hans": "时区（IANA）",
    "zh-Hant": "時區（IANA）",
    "vi": "Múi giờ (IANA)",
    "fil": "Time zone (IANA)",
  },
  "Reminder requested: {time} ({zone})": {
    "es": "Recordatorio solicitado: {time} ({zone})",
    "zh-Hans": "已请求提醒：{time}（{zone}）",
    "zh-Hant": "已要求提醒：{time}（{zone}）",
    "vi": "Đã yêu cầu nhắc: {time} ({zone})",
    "fil": "Hiniling na paalala: {time} ({zone})",
  },
  "You have a Safe at Home next step.": {
    "es": "Tiene un próximo paso en Safe at Home.",
    "zh-Hans": "您有一项 Safe at Home 后续步骤。",
    "zh-Hant": "您有一項 Safe at Home 後續步驟。",
    "vi": "Bạn có một bước tiếp theo trong Safe at Home.",
    "fil": "May susunod kang hakbang sa Safe at Home.",
  },
  "Choose a valid future date, time, and IANA time zone.": {
    "es": "Elija una fecha futura, hora y zona IANA válidas.",
    "zh-Hans": "请选择有效的未来日期、时间和 IANA 时区。",
    "zh-Hant": "請選擇有效的未來日期、時間和 IANA 時區。",
    "vi": "Chọn ngày giờ tương lai và múi giờ IANA hợp lệ.",
    "fil": "Pumili ng wastong petsa at oras sa hinaharap at IANA time zone.",
  },
  "Notifications are off. Due tasks remain available in the app.": {
    "es":
        "Las notificaciones están desactivadas. Las tareas siguen disponibles en la app.",
    "zh-Hans": "通知已关闭。仍可在应用中查看到期任务。",
    "zh-Hant": "通知已關閉。仍可在應用程式中查看到期任務。",
    "vi": "Thông báo đã tắt. Công việc đến hạn vẫn có trong ứng dụng.",
    "fil":
        "Naka-off ang mga notification. Makikita pa rin sa app ang mga takdang gawain.",
  },
  "A reminder could not be scheduled. Your task is still saved.": {
    "es": "No se pudo programar un recordatorio. Su tarea sigue guardada.",
    "zh-Hans": "无法安排提醒。任务仍已保存。",
    "zh-Hant": "無法安排提醒。任務仍已儲存。",
    "vi": "Không thể lên lịch nhắc. Công việc vẫn được lưu.",
    "fil": "Hindi maiiskedyul ang paalala. Naka-save pa rin ang gawain.",
  },
  "Only the next 48 reminders are scheduled. Open the app to refresh.": {
    "es":
        "Solo se programan los próximos 48 recordatorios. Abra la app para actualizar.",
    "zh-Hans": "仅安排最近的48条提醒。请打开应用刷新。",
    "zh-Hant": "僅安排最近的48則提醒。請開啟應用程式更新。",
    "vi": "Chỉ lên lịch 48 lời nhắc tiếp theo. Mở ứng dụng để cập nhật.",
    "fil":
        "Ang susunod na 48 paalala lang ang naka-iskedyul. Buksan ang app para i-refresh.",
  },
  "Offline copy. Refresh before changing tasks.": {
    "es": "Copia sin conexión. Actualice antes de cambiar tareas.",
    "zh-Hans": "离线副本。更改任务前请刷新。",
    "zh-Hant": "離線副本。變更任務前請更新。",
    "vi": "Bản ngoại tuyến. Cập nhật trước khi sửa công việc.",
    "fil": "Offline na kopya. I-refresh bago baguhin ang mga gawain.",
  },
  "The plan changed. Reopen it before editing next steps.": {
    "es": "El plan cambió. Ábralo de nuevo antes de editar los próximos pasos.",
    "zh-Hans": "计划已更改。编辑后续步骤前请重新打开。",
    "zh-Hant": "計畫已變更。編輯後續步驟前請重新開啟。",
    "vi": "Kế hoạch đã đổi. Mở lại trước khi sửa các bước tiếp theo.",
    "fil":
        "Nagbago ang plano. Buksan muli bago i-edit ang mga susunod na hakbang.",
  },
  "No tracked programs. Choose Track program under possible assistance.": {
    "es":
        "No hay programas seguidos. Elija Seguir programa en asistencia posible.",
    "zh-Hans": "尚未跟踪项目。请在可能的援助中选择跟踪项目。",
    "zh-Hant": "尚未追蹤計畫。請在可能的援助中選擇追蹤計畫。",
    "vi":
        "Chưa theo dõi chương trình. Chọn Theo dõi chương trình trong mục hỗ trợ có thể có.",
    "fil":
        "Walang sinusubaybayang programa. Piliin ang Subaybayan ang programa sa posibleng tulong.",
  },
  "No next steps yet. Add a task for this plan or a tracked program.": {
    "es":
        "No hay próximos pasos. Añada una tarea para este plan o un programa seguido.",
    "zh-Hans": "暂无后续步骤。请为此计划或已跟踪项目添加任务。",
    "zh-Hant": "暫無後續步驟。請為此計畫或已追蹤計畫新增任務。",
    "vi":
        "Chưa có bước tiếp theo. Thêm công việc cho kế hoạch hoặc chương trình đã theo dõi.",
    "fil":
        "Wala pang susunod na hakbang. Magdagdag ng gawain para sa plano o programa.",
  },
  "No longer in the current program registry. History is retained.": {
    "es": "Ya no está en el registro actual. Se conserva el historial.",
    "zh-Hans": "已不在当前项目目录中。历史记录仍保留。",
    "zh-Hant": "已不在目前計畫目錄中。歷史紀錄仍保留。",
    "vi": "Không còn trong danh mục hiện tại. Lịch sử vẫn được giữ.",
    "fil": "Wala na sa kasalukuyang talaan. Napanatili ang kasaysayan.",
  },
  "Manual reports do not verify submission, eligibility, approval, or completed repairs.": {
    "es":
        "Los informes manuales no verifican envío, elegibilidad, aprobación ni reparaciones completadas.",
    "zh-Hans": "手动报告不能验证提交、资格、批准或维修完成。",
    "zh-Hant": "手動回報不能驗證提交、資格、核准或維修完成。",
    "vi":
        "Báo cáo thủ công không xác minh việc nộp, điều kiện, phê duyệt hay sửa chữa hoàn tất.",
    "fil":
        "Hindi pinatutunayan ng manwal na ulat ang pagsumite, pagiging kwalipikado, pag-apruba, o tapos na pagkukumpuni.",
  },
  "Due dates are personal targets. They are not verified agency deadlines. A responsible person label does not share this plan or assign a signed-in helper.": {
    "es":
        "Las fechas son metas personales, no plazos verificados de la agencia. Nombrar a una persona no comparte el plan ni asigna un ayudante conectado.",
    "zh-Hans": "到期日是个人目标，不是经验证的机构截止日。负责人标签不会共享计划或向已登录的协助者分派任务。",
    "zh-Hant": "到期日是個人目標，不是經驗證的機構截止日。負責人標籤不會分享計畫或向已登入的協助者指派任務。",
    "vi":
        "Ngày đến hạn là mục tiêu cá nhân, không phải hạn do cơ quan xác nhận. Nhãn người phụ trách không chia sẻ kế hoạch hay phân công người hỗ trợ đã đăng nhập.",
    "fil":
        "Personal na target ang mga petsa, hindi kumpirmadong deadline ng ahensya. Ang pangalan ng responsable ay hindi nagbabahagi ng plano o nagtatalaga ng naka-sign in na katulong.",
  },
  "A name or role is a label only. This does not give anyone access to the plan.": {
    "es": "El nombre o rol es solo una etiqueta. No da acceso al plan.",
    "zh-Hans": "姓名或角色仅是标签，不会授予计划访问权。",
    "zh-Hant": "姓名或角色僅是標籤，不會授予計畫存取權。",
    "vi": "Tên hoặc vai trò chỉ là nhãn, không cấp quyền truy cập kế hoạch.",
    "fil":
        "Label lang ang pangalan o tungkulin. Hindi ito nagbibigay ng access sa plano.",
  },
  "Reminders stay in the chosen time zone when you travel. A repeated daylight-saving time uses the earlier occurrence; choose another time if the clock skips it.": {
    "es":
        "Los recordatorios mantienen la zona elegida al viajar. Si la hora se repite por cambio de horario, se usa la primera; si se omite, elija otra hora.",
    "zh-Hans": "旅行时提醒保留所选时区。夏令时导致时间重复时使用较早的一次；时间被跳过时请选择其他时间。",
    "zh-Hant": "旅行時提醒保留所選時區。日光節約時間導致時間重複時使用較早的一次；時間被跳過時請選擇其他時間。",
    "vi":
        "Lời nhắc giữ múi giờ đã chọn khi đi xa. Giờ lặp do đổi giờ mùa hè dùng lần sớm hơn; nếu giờ bị bỏ qua, hãy chọn giờ khác.",
    "fil":
        "Mananatili sa piniling time zone ang paalala kapag naglakbay. Kung umulit ang oras dahil sa daylight saving, ang mas maaga ang gagamitin; pumili ng iba kung nilaktawan ang oras.",
  },
  "Reminders are local to this device. Open the app to sync remote changes. Device settings may delay or prevent delivery.": {
    "es":
        "Los recordatorios son locales a este dispositivo. Abra la app para sincronizar cambios remotos. Los ajustes pueden retrasar o impedir la entrega.",
    "zh-Hans": "提醒仅限此设备。请打开应用同步远程更改。设备设置可能延迟或阻止通知送达。",
    "zh-Hant": "提醒僅限此裝置。請開啟應用程式同步遠端變更。裝置設定可能延遲或阻止通知送達。",
    "vi":
        "Lời nhắc chỉ có trên thiết bị này. Mở ứng dụng để đồng bộ thay đổi từ xa. Cài đặt thiết bị có thể trì hoãn hoặc chặn thông báo.",
    "fil":
        "Lokal sa device na ito ang mga paalala. Buksan ang app para i-sync ang mga pagbabago. Maaaring maantala o hindi maihatid dahil sa mga setting.",
  },
  "A save is pending. Retry the same change or refresh and review saved state before discarding it.": {
    "es":
        "Hay un guardado pendiente. Reintente el mismo cambio o actualice y revise lo guardado antes de descartarlo.",
    "zh-Hans": "有待确认的保存。请重试同一更改，或刷新并审核已保存状态后再放弃。",
    "zh-Hant": "有待確認的儲存。請重試同一變更，或更新並審核已儲存狀態後再放棄。",
    "vi":
        "Có lần lưu đang chờ. Thử lại cùng thay đổi hoặc cập nhật và xem dữ liệu đã lưu trước khi bỏ.",
    "fil":
        "May nakabinbing pag-save. Subukang muli ang parehong pagbabago o i-refresh at suriin ang naka-save bago itapon.",
  },
  "Retry pending save": {
    "es": "Reintentar guardado pendiente",
    "zh-Hans": "重试待确认保存",
    "zh-Hant": "重試待確認儲存",
    "vi": "Thử lại lần lưu đang chờ",
    "fil": "Subukang muli ang nakabinbing pag-save",
  },
  "Review and discard pending save": {
    "es": "Revisar y descartar guardado pendiente",
    "zh-Hans": "审核并放弃待确认保存",
    "zh-Hant": "審核並放棄待確認儲存",
    "vi": "Xem lại và bỏ lần lưu đang chờ",
    "fil": "Suriin at itapon ang nakabinbing pag-save",
  },
  "Discard pending change?": {
    "es": "¿Descartar cambio pendiente?",
    "zh-Hans": "放弃待确认更改？",
    "zh-Hant": "放棄待確認變更？",
    "vi": "Bỏ thay đổi đang chờ?",
    "fil": "Itapon ang nakabinbing pagbabago?",
  },
  "Review saved state first. Discarding this attempt does not undo a change already saved online.": {
    "es":
        "Revise primero lo guardado. Descartar este intento no deshace cambios ya guardados en línea.",
    "zh-Hans": "请先审核已保存状态。放弃此次尝试不会撤销已在线保存的更改。",
    "zh-Hant": "請先審核已儲存狀態。放棄此次嘗試不會復原已在線上儲存的變更。",
    "vi":
        "Xem dữ liệu đã lưu trước. Bỏ lần thử này không hoàn tác thay đổi đã lưu trực tuyến.",
    "fil":
        "Suriin muna ang naka-save. Hindi mababawi ng pagtatapon ang pagbabagong naka-save na online.",
  },
  "Device reminder settings could not be read. Reset them to choose new reminders. Your tasks are still saved.": {
    "es":
        "No se pudieron leer los ajustes de recordatorios del dispositivo. Restablézcalos para elegir nuevos recordatorios. Sus tareas siguen guardadas.",
    "zh-Hans": "无法读取设备提醒设置。请重置后选择新提醒。任务仍已保存。",
    "zh-Hant": "無法讀取裝置提醒設定。請重設後選擇新提醒。任務仍已儲存。",
    "vi":
        "Không thể đọc cài đặt nhắc trên thiết bị. Đặt lại để chọn lời nhắc mới. Công việc vẫn được lưu.",
    "fil":
        "Hindi mabasa ang mga setting ng paalala sa device. I-reset para pumili ng mga bagong paalala. Naka-save pa rin ang mga gawain.",
  },
  "This device has 128 active reminders. Disable one before adding another.": {
    "es":
        "Este dispositivo tiene 128 recordatorios activos. Desactive uno antes de añadir otro.",
    "zh-Hans": "此设备有128条有效提醒。请先关闭一条再添加新提醒。",
    "zh-Hant": "此裝置有128則有效提醒。請先關閉一則再新增提醒。",
    "vi":
        "Thiết bị có 128 lời nhắc đang bật. Tắt một lời nhắc trước khi thêm lời nhắc khác.",
    "fil":
        "May 128 aktibong paalala ang device na ito. I-off muna ang isa bago magdagdag.",
  },
  "Reset device reminders?": {
    "es": "¿Restablecer los recordatorios del dispositivo?",
    "zh-Hans": "重置设备提醒？",
    "zh-Hant": "重設裝置提醒？",
    "vi": "Đặt lại lời nhắc trên thiết bị?",
    "fil": "I-reset ang mga paalala sa device?",
  },
  "Reset device reminders": {
    "es": "Restablecer recordatorios del dispositivo",
    "zh-Hans": "重置设备提醒",
    "zh-Hant": "重設裝置提醒",
    "vi": "Đặt lại lời nhắc trên thiết bị",
    "fil": "I-reset ang mga paalala sa device",
  },
  "This removes reminder times on this device. Your tasks and target dates stay saved. Enable each reminder again when ready.": {
    "es":
        "Esto elimina las horas de recordatorio de este dispositivo. Sus tareas y fechas objetivo siguen guardadas. Active cada recordatorio de nuevo cuando lo desee.",
    "zh-Hans": "这会删除此设备上的提醒时间。任务和目标日期仍已保存。准备好后请逐个重新启用提醒。",
    "zh-Hant": "這會刪除此裝置上的提醒時間。任務和目標日期仍已儲存。準備好後請逐個重新啟用提醒。",
    "vi":
        "Thao tác này xóa giờ nhắc trên thiết bị này. Công việc và ngày mục tiêu vẫn được lưu. Bật lại từng lời nhắc khi sẵn sàng.",
    "fil":
        "Aalisin nito ang mga oras ng paalala sa device na ito. Mananatiling naka-save ang mga gawain at target na petsa. I-on muli ang bawat paalala kapag handa na.",
  },
  "Unresolved program requirements: {count}": {
    "es": "Requisitos del programa sin resolver: {count}",
    "zh-Hans": "待解决的项目要求：{count}",
    "zh-Hant": "待解決的計畫要求：{count}",
    "vi": "Yêu cầu chương trình chưa giải quyết: {count}",
    "fil": "Hindi pa nalulutas na kinakailangan ng programa: {count}",
  },
  "Open tasks: {count}": {
    "es": "Tareas abiertas: {count}",
    "zh-Hans": "未完成任务：{count}",
    "zh-Hant": "未完成任務：{count}",
    "vi": "Công việc chưa hoàn tất: {count}",
    "fil": "Mga hindi pa tapos na gawain: {count}",
  },
};
