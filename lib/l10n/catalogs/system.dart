const systemTranslations = <String, Map<String, String>>{
  'Could not start': {
    'es': 'No se pudo iniciar',
    'zh-Hans': '无法启动',
    'zh-Hant': '無法啟動',
    'vi': 'Không thể khởi động',
    'fil': 'Hindi makapagsimula',
  },
  'Private storage': {
    'es': 'Almacenamiento privado',
    'zh-Hans': '私人存储',
    'zh-Hant': '私人儲存空間',
    'vi': 'Bộ nhớ riêng tư',
    'fil': 'Pribadong imbakan',
  },
  'Finish private cleanup': {
    'es': 'Completar limpieza privada',
    'zh-Hans': '完成私人数据清理',
    'zh-Hant': '完成私人資料清理',
    'vi': 'Hoàn tất xóa dữ liệu riêng tư',
    'fil': 'Tapusin ang paglilinis ng pribadong datos',
  },
  'Retry private cleanup': {
    'es': 'Reintentar limpieza privada',
    'zh-Hans': '重试清理私人数据',
    'zh-Hant': '重試清理私人資料',
    'vi': 'Thử xóa dữ liệu riêng tư lại',
    'fil': 'Subukang muli ang paglilinis ng pribadong datos',
  },
  'Sign out and keep device drafts': {
    'es': 'Cerrar sesión y conservar borradores en el dispositivo',
    'zh-Hans': '退出登录并保留设备草稿',
    'zh-Hant': '登出並保留裝置草稿',
    'vi': 'Đăng xuất và giữ bản nháp trên thiết bị',
    'fil': 'Mag-sign out at panatilihin ang mga draft sa device',
  },
  'Finishing sign-out': {
    'es': 'Completando cierre de sesión',
    'zh-Hans': '正在退出登录',
    'zh-Hant': '正在登出',
    'vi': 'Đang hoàn tất đăng xuất',
    'fil': 'Tinatapos ang pag-sign out',
  },
  'Opening secure session': {
    'es': 'Abriendo sesión segura',
    'zh-Hans': '正在开启安全会话',
    'zh-Hant': '正在開啟安全工作階段',
    'vi': 'Đang mở phiên an toàn',
    'fil': 'Binubuksan ang ligtas na sesyon',
  },
  'Finishing private account cleanup': {
    'es': 'Completando limpieza privada de la cuenta',
    'zh-Hans': '正在完成账户私人数据清理',
    'zh-Hant': '正在完成帳號私人資料清理',
    'vi': 'Đang hoàn tất xóa dữ liệu riêng tư của tài khoản',
    'fil': 'Tinatapos ang paglilinis ng pribadong datos ng account',
  },
  'Safe at Home could not start. Close and reopen the app. If this keeps happening, ask your project owner for help. No case has been opened.': {
    'es':
        'Safe at Home no pudo iniciar. Cierre y vuelva a abrir la aplicación. Si el problema continúa, pida ayuda al responsable del proyecto. No se ha abierto ningún caso.',
    'zh-Hans': 'Safe at Home 无法启动。请关闭并重新打开应用。如果问题持续，请向项目负责人求助。尚未打开任何档案。',
    'zh-Hant': 'Safe at Home 無法啟動。請關閉並重新開啟應用程式。如果問題持續，請向專案負責人求助。尚未開啟任何檔案。',
    'vi':
        'Safe at Home không thể khởi động. Hãy đóng rồi mở lại ứng dụng. Nếu lỗi tiếp diễn, nhờ người phụ trách dự án giúp. Chưa có hồ sơ nào được mở.',
    'fil':
        'Hindi makapagsimula ang Safe at Home. Isara at buksan muli ang app. Kung magpatuloy ang problema, humingi ng tulong sa may-ari ng proyekto. Walang kasong nabuksan.',
  },
  'Private storage could not be opened. Unlock your phone and restart the app.': {
    'es':
        'No se pudo abrir el almacenamiento privado. Desbloquee el teléfono y reinicie la aplicación.',
    'zh-Hans': '无法打开私人存储。请解锁手机并重新启动应用。',
    'zh-Hant': '無法開啟私人儲存空間。請解鎖手機並重新啟動應用程式。',
    'vi':
        'Không thể mở bộ nhớ riêng tư. Mở khóa điện thoại và khởi động lại ứng dụng.',
    'fil':
        'Hindi mabuksan ang pribadong imbakan. I-unlock ang telepono at buksan muli ang app.',
  },
  'Sign-out is not complete. Saved sign-in data or other requested private cleanup could not be confirmed. Unlock this device and retry before signing in again. Retrying finishes only the cleanup you already requested.': {
    'es':
        'El cierre de sesión no está completo. No se pudo confirmar la eliminación de los datos de inicio de sesión u otra limpieza privada solicitada. Desbloquee este dispositivo y reintente antes de volver a iniciar sesión. El reintento solo completa la limpieza que ya solicitó.',
    'zh-Hans':
        '退出登录尚未完成。无法确认已保存的登录数据或其他请求的私人数据清理是否完成。请解锁此设备并重试，然后再登录。重试只会完成您已经请求的清理。',
    'zh-Hant':
        '登出尚未完成。無法確認已儲存的登入資料或其他要求的私人資料清理是否完成。請解鎖此裝置並重試，然後再登入。重試只會完成您已經要求的清理。',
    'vi':
        'Đăng xuất chưa hoàn tất. Chưa xác nhận được việc xóa thông tin đăng nhập đã lưu hoặc dữ liệu riêng tư đã yêu cầu. Mở khóa thiết bị và thử lại trước khi đăng nhập. Thử lại chỉ hoàn tất việc xóa bạn đã yêu cầu.',
    'fil':
        'Hindi pa tapos ang pag-sign out. Hindi makumpirma ang paglilinis ng naka-save na datos sa pag-sign in o iba pang hiniling na pribadong paglilinis. I-unlock ang device at subukang muli bago mag-sign in. Tatapusin lamang nito ang paglilinis na hiniling mo na.',
  },
  'Encrypted drafts will remain on this device. To remove them, unlock your phone, sign in to this account, and use Settings after private storage opens.': {
    'es':
        'Los borradores cifrados permanecerán en este dispositivo. Para eliminarlos, desbloquee el teléfono, inicie sesión en esta cuenta y use Configuración cuando se abra el almacenamiento privado.',
    'zh-Hans': '加密草稿将保留在此设备上。如需删除，请解锁手机、登录此账户，并在私人存储打开后使用设置。',
    'zh-Hant': '加密草稿將保留在此裝置上。如需刪除，請解鎖手機、登入此帳號，並在私人儲存空間開啟後使用設定。',
    'vi':
        'Bản nháp mã hóa vẫn nằm trên thiết bị. Để xóa, hãy mở khóa điện thoại, đăng nhập tài khoản này và dùng Cài đặt sau khi mở được bộ nhớ riêng tư.',
    'fil':
        'Mananatili sa device na ito ang mga naka-encrypt na draft. Para alisin ang mga ito, i-unlock ang telepono, mag-sign in sa account na ito at gamitin ang Settings kapag nabuksan na ang pribadong imbakan.',
  },
};
