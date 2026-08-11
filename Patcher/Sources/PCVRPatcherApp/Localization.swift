import Foundation

/// Small, dependency-free localization catalog for the standalone patcher.
/// The language follows the first macOS preferred language. Unknown languages
/// intentionally fall back to English instead of exposing localization keys.
enum L10n {
    enum Key: String, CaseIterable {
        case appTitle
        case subtitle
        case about
        case aboutBody
        case done
        case safetyBody
        case dropTitle
        case dropSubtitle
        case choose
        case original
        case output
        case remove
        case inspect
        case repair
        case create
        case activity
        case cancel
        case ok
        case removeConfirmTitle
        case removeConfirmMessage
        case selectOfficial
        case selectPlayCover
        case unsupportedItem
        case dropOnly
        case notInspected
        case originalMissing
        case vrChatMissing
        case ready
        case controllerRequired
        case installed
        case repairRequired
        case unsupportedRuntime
        case applicationsRunning
        case unknownModification
        case sourceOnly
        case notInspectedDetail
        case originalMissingDetail
        case vrChatMissingDetail
        case readyDetail
        case controllerRequiredDetail
        case installedDetail
        case repairDetail
        case unsupportedRuntimeDetail
        case applicationsRunningDetail
        case unknownModificationDetail
        case sourceOnlyDetail
        case selectedLog
        case inspectionLog
        case inspectionFailedLog
        case operationCreate
        case operationRepair
        case operationRemove
        case operationCompleteLog
        case operationStoppedLog
        case independentLibraryLog
        case manifestMissing
        case startupIncomplete
        case cannotConfigure
    }

    private enum Language: Hashable {
        case english
        case simplifiedChinese
        case traditionalChinese
        case japanese
        case korean
        case spanish
        case french
        case german
        case russian
        case portuguese
        case vietnamese
    }

    private static var language: Language {
        let identifier = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if identifier.hasPrefix("zh-hant") || identifier.hasPrefix("zh-tw") || identifier.hasPrefix("zh-hk") {
            return .traditionalChinese
        }
        if identifier.hasPrefix("zh") { return .simplifiedChinese }
        if identifier.hasPrefix("ja") { return .japanese }
        if identifier.hasPrefix("ko") { return .korean }
        if identifier.hasPrefix("es") { return .spanish }
        if identifier.hasPrefix("fr") { return .french }
        if identifier.hasPrefix("de") { return .german }
        if identifier.hasPrefix("ru") { return .russian }
        if identifier.hasPrefix("pt") { return .portuguese }
        if identifier.hasPrefix("vi") { return .vietnamese }
        return .english
    }

    private static let english: [Key: String] = [
        .appTitle: "PlayCover VRChat Patcher",
        .subtitle: "VRChat memory patch",
        .about: "About",
        .aboutBody: "Open source. Not affiliated with PlayCover or VRChat.",
        .done: "Done",
        .safetyBody: "Original app stays untouched.",
        .dropTitle: "Drop PlayCover.app",
        .dropSubtitle: "or choose the official app",
        .choose: "Choose PlayCover…",
        .original: "Original",
        .output: "Creates",
        .remove: "Remove copy",
        .inspect: "Check",
        .repair: "Repair",
        .create: "Create copy",
        .activity: "Activity",
        .cancel: "Cancel",
        .ok: "OK",
        .removeConfirmTitle: "Remove PlayCover VRChat?",
        .removeConfirmMessage: "Only the patched app is removed. PlayCover, the game library, and VRChat data stay.",
        .selectOfficial: "Select the official PlayCover application",
        .selectPlayCover: "Select PlayCover",
        .unsupportedItem: "Unsupported item",
        .dropOnly: "Drop PlayCover.app, not another file.",
        .notInspected: "Drop PlayCover.app",
        .originalMissing: "PlayCover not found",
        .vrChatMissing: "VRChat not found",
        .ready: "Ready",
        .controllerRequired: "Install helper",
        .installed: "Ready to play",
        .repairRequired: "Repair needed",
        .unsupportedRuntime: "Unsupported Mac",
        .applicationsRunning: "Close apps",
        .unknownModification: "Unknown changes",
        .sourceOnly: "Developer build",
        .notInspectedDetail: "Drop the official app to begin.",
        .originalMissingDetail: "Choose the official PlayCover app.",
        .vrChatMissingDetail: "Install the supported VRChat build first: %@",
        .readyDetail: "Original verified. It will not be changed.",
        .controllerRequiredDetail: "Install the helper to continue. (%@)",
        .installedDetail: "Ready. VRChat memory settings are in the app settings.",
        .repairDetail: "Finish the interrupted setup.",
        .unsupportedRuntimeDetail: "%@",
        .applicationsRunningDetail: "Close %@, then check again.",
        .unknownModificationDetail: "No changes made. %@",
        .sourceOnlyDetail: "Inspection only; this build has no payload.",
        .selectedLog: "Selected %@",
        .inspectionLog: "Status: %@",
        .inspectionFailedLog: "Check failed",
        .operationCreate: "Creating copy",
        .operationRepair: "Repairing",
        .operationRemove: "Removing copy",
        .operationCompleteLog: "Done: %@",
        .operationStoppedLog: "Stopped safely",
        .independentLibraryLog: "Game library: %@",
        .manifestMissing: "Compatibility manifest is missing.",
        .startupIncomplete: "Patcher is incomplete.",
        .cannotConfigure: "Cannot configure patcher."
    ]

    private static let translations: [Language: [Key: String]] = [
        .simplifiedChinese: [
            .subtitle: "简洁的 VRChat 兼容工具", .about: "关于", .aboutBody: "非官方开源项目，与 PlayCover 或 VRChat 无隶属关系。", .done: "完成", .manifestMissing: "缺少兼容性清单。", .startupIncomplete: "Patcher 不完整。", .cannotConfigure: "无法配置 Patcher。",
            .safetyBody: "官方 App 不会被修改。工具会创建独立的 PlayCover VRChat 和游戏库。", .dropTitle: "拖入 PlayCover.app", .dropSubtitle: "或选择官方 App", .choose: "选择 PlayCover…", .original: "原版", .output: "创建", .remove: "移除副本", .inspect: "检查", .repair: "修复", .create: "创建副本", .activity: "活动", .cancel: "取消", .ok: "好", .removeConfirmTitle: "移除 PlayCover VRChat？", .removeConfirmMessage: "只移除补丁 App；PlayCover、游戏库和 VRChat 数据会保留。", .selectOfficial: "选择官方 PlayCover 应用", .selectPlayCover: "选择 PlayCover", .unsupportedItem: "不支持的项目", .dropOnly: "请拖入 PlayCover.app。", .notInspected: "拖入 PlayCover.app", .originalMissing: "未找到 PlayCover", .vrChatMissing: "未找到 VRChat", .ready: "可以创建", .controllerRequired: "安装组件", .installed: "已就绪", .repairRequired: "需要修复", .unsupportedRuntime: "环境不支持", .applicationsRunning: "请先退出应用", .unknownModification: "检测到未知修改", .sourceOnly: "开发构建", .notInspectedDetail: "拖入官方 App 开始。", .originalMissingDetail: "请选择官方 PlayCover。", .vrChatMissingDetail: "请先安装受支持的 VRChat：%@", .readyDetail: "原版已验证，不会被修改。", .controllerRequiredDetail: "安装组件后继续。（%@）", .installedDetail: "已就绪。可在 VRChat 应用设置中调整内存。", .repairDetail: "完成中断的安装。", .unsupportedRuntimeDetail: "%@", .applicationsRunningDetail: "请退出 %@，然后重新检查。", .unknownModificationDetail: "未进行修改。%@", .sourceOnlyDetail: "仅可检查；此构建不含 Payload。", .selectedLog: "已选择 %@", .inspectionLog: "状态：%@", .inspectionFailedLog: "检查失败", .operationCreate: "正在创建副本", .operationRepair: "正在修复", .operationRemove: "正在移除副本", .operationCompleteLog: "完成：%@", .operationStoppedLog: "已安全停止", .independentLibraryLog: "游戏库：%@"
        ],
        .traditionalChinese: [
            .subtitle: "簡潔的 VRChat 相容工具", .about: "關於", .aboutBody: "非官方開源專案，與 PlayCover 或 VRChat 無隸屬關係。", .done: "完成", .safetyBody: "官方 App 不會被修改。工具會建立獨立的 PlayCover VRChat 與遊戲庫。", .dropTitle: "拖入 PlayCover.app", .dropSubtitle: "或選擇官方 App", .choose: "選擇 PlayCover…", .original: "原版", .output: "建立", .remove: "移除副本", .inspect: "檢查", .repair: "修復", .create: "建立副本", .activity: "活動", .cancel: "取消", .ok: "好", .removeConfirmTitle: "移除 PlayCover VRChat？", .removeConfirmMessage: "只移除補丁 App；PlayCover、遊戲庫和 VRChat 資料會保留。", .selectOfficial: "選擇官方 PlayCover 應用程式", .selectPlayCover: "選擇 PlayCover", .unsupportedItem: "不支援的項目", .dropOnly: "請拖入 PlayCover.app。", .notInspected: "拖入 PlayCover.app", .originalMissing: "找不到 PlayCover", .vrChatMissing: "找不到 VRChat", .ready: "可以建立", .controllerRequired: "安裝元件", .installed: "已就緒", .repairRequired: "需要修復", .unsupportedRuntime: "環境不支援", .applicationsRunning: "請先退出應用程式", .unknownModification: "偵測到未知修改", .sourceOnly: "開發版本", .notInspectedDetail: "拖入官方 App 開始。", .originalMissingDetail: "請選擇官方 PlayCover。", .vrChatMissingDetail: "請先安裝支援的 VRChat：%@", .readyDetail: "原版已驗證，不會被修改。", .controllerRequiredDetail: "安裝元件後繼續。（%@）", .installedDetail: "已就緒。可在 VRChat 應用程式設定調整記憶體。", .repairDetail: "完成中斷的安裝。", .unsupportedRuntimeDetail: "%@", .applicationsRunningDetail: "請退出 %@，然後重新檢查。", .unknownModificationDetail: "未進行修改。%@", .sourceOnlyDetail: "僅可檢查；此版本不含 Payload。", .selectedLog: "已選擇 %@", .inspectionLog: "狀態：%@", .inspectionFailedLog: "檢查失敗", .operationCreate: "正在建立副本", .operationRepair: "正在修復", .operationRemove: "正在移除副本", .operationCompleteLog: "完成：%@", .operationStoppedLog: "已安全停止", .independentLibraryLog: "遊戲庫：%@"
        ],
        .japanese: [.subtitle: "VRChat 用の互換ツール", .about: "このアプリについて", .done: "完了", .safetyBody: "公式アプリは変更しません。専用の PlayCover VRChat とゲームライブラリを作成します。", .dropTitle: "PlayCover.app をドロップ", .dropSubtitle: "または公式アプリを選択", .choose: "PlayCover を選択…", .remove: "コピーを削除", .inspect: "確認", .repair: "修復", .create: "コピーを作成", .activity: "アクティビティ", .cancel: "キャンセル", .ok: "OK", .removeConfirmTitle: "PlayCover VRChat を削除しますか？", .removeConfirmMessage: "パッチ版だけを削除します。公式アプリとゲームデータは残ります。", .notInspected: "PlayCover.app をドロップ", .originalMissing: "PlayCover がありません", .vrChatMissing: "VRChat がありません", .ready: "準備完了", .controllerRequired: "ヘルパーをインストール", .installed: "起動できます", .repairRequired: "修復が必要", .unsupportedRuntime: "非対応の Mac", .applicationsRunning: "アプリを終了", .unknownModification: "不明な変更", .sourceOnly: "開発ビルド", .notInspectedDetail: "公式アプリをドロップして開始します。", .originalMissingDetail: "公式 PlayCover を選択してください。", .vrChatMissingDetail: "対応する VRChat を先にインストールしてください：%@", .readyDetail: "公式アプリを確認しました。変更しません。", .controllerRequiredDetail: "続行するにはヘルパーをインストールします。（%@）", .installedDetail: "準備完了。メモリ設定は VRChat のアプリ設定にあります。", .repairDetail: "中断したセットアップを完了します。", .applicationsRunningDetail: "%@ を終了して、もう一度確認してください。", .selectedLog: "%@ を選択", .inspectionLog: "状態：%@", .inspectionFailedLog: "確認に失敗", .operationCreate: "コピーを作成中", .operationRepair: "修復中", .operationRemove: "コピーを削除中", .operationCompleteLog: "完了：%@", .operationStoppedLog: "安全に停止", .independentLibraryLog: "ゲームライブラリ：%@"],
        .korean: [.subtitle: "VRChat 호환 도구", .about: "정보", .done: "완료", .safetyBody: "공식 앱은 수정하지 않습니다. 별도의 PlayCover VRChat과 게임 라이브러리를 만듭니다.", .dropTitle: "PlayCover.app 놓기", .dropSubtitle: "또는 공식 앱 선택", .choose: "PlayCover 선택…", .remove: "복사본 제거", .inspect: "확인", .repair: "복구", .create: "복사본 만들기", .activity: "활동", .cancel: "취소", .ok: "확인", .removeConfirmTitle: "PlayCover VRChat을 제거할까요?", .removeConfirmMessage: "패치된 앱만 제거하며 공식 앱과 게임 데이터는 보존됩니다.", .notInspected: "PlayCover.app 놓기", .originalMissing: "PlayCover 없음", .vrChatMissing: "VRChat 없음", .ready: "준비됨", .controllerRequired: "도우미 설치", .installed: "실행 준비됨", .repairRequired: "복구 필요", .unsupportedRuntime: "지원되지 않는 Mac", .applicationsRunning: "앱 종료", .unknownModification: "알 수 없는 변경", .sourceOnly: "개발자 빌드", .notInspectedDetail: "공식 앱을 놓아 시작하세요.", .originalMissingDetail: "공식 PlayCover를 선택하세요.", .vrChatMissingDetail: "지원되는 VRChat을 먼저 설치하세요: %@", .readyDetail: "공식 앱이 확인되었습니다. 변경하지 않습니다.", .controllerRequiredDetail: "계속하려면 도우미를 설치하세요. (%@)", .installedDetail: "준비됨. 메모리 설정은 VRChat 앱 설정에 있습니다.", .repairDetail: "중단된 설치를 완료하세요.", .applicationsRunningDetail: "%@을(를) 종료한 뒤 다시 확인하세요.", .selectedLog: "%@ 선택됨", .inspectionLog: "상태: %@", .inspectionFailedLog: "확인 실패", .operationCreate: "복사본 만드는 중", .operationRepair: "복구 중", .operationRemove: "복사본 제거 중", .operationCompleteLog: "완료: %@", .operationStoppedLog: "안전하게 중지됨", .independentLibraryLog: "게임 라이브러리: %@"],
        .spanish: [.subtitle: "Herramienta de compatibilidad para VRChat", .about: "Acerca de", .done: "Listo", .safetyBody: "La app oficial no se modifica. Se crean una copia y una biblioteca independientes.", .dropTitle: "Suelta PlayCover.app", .dropSubtitle: "o elige la app oficial", .choose: "Elegir PlayCover…", .remove: "Eliminar copia", .inspect: "Comprobar", .repair: "Reparar", .create: "Crear copia", .activity: "Actividad", .cancel: "Cancelar", .ok: "Aceptar", .removeConfirmTitle: "¿Eliminar PlayCover VRChat?", .removeConfirmMessage: "Solo se elimina la app parcheada. La app oficial y los datos se conservan.", .notInspected: "Suelta PlayCover.app", .originalMissing: "PlayCover no encontrado", .vrChatMissing: "VRChat no encontrado", .ready: "Listo", .controllerRequired: "Instalar componente", .installed: "Listo para jugar", .repairRequired: "Reparación necesaria", .unsupportedRuntime: "Mac no compatible", .applicationsRunning: "Cierra las apps", .unknownModification: "Cambios desconocidos", .sourceOnly: "Versión de desarrollo", .notInspectedDetail: "Suelta la app oficial para empezar.", .originalMissingDetail: "Elige el PlayCover oficial.", .vrChatMissingDetail: "Instala primero la versión compatible de VRChat: %@", .readyDetail: "La app oficial está verificada y no se modificará.", .controllerRequiredDetail: "Instala el componente para continuar. (%@)", .installedDetail: "Listo. Ajusta la memoria en los ajustes de VRChat.", .repairDetail: "Completa la instalación interrumpida.", .applicationsRunningDetail: "Cierra %@ y vuelve a comprobar.", .selectedLog: "Seleccionado %@", .inspectionLog: "Estado: %@", .inspectionFailedLog: "Error al comprobar", .operationCreate: "Creando copia", .operationRepair: "Reparando", .operationRemove: "Eliminando copia", .operationCompleteLog: "Listo: %@", .operationStoppedLog: "Detenido de forma segura", .independentLibraryLog: "Biblioteca: %@"],
        .french: [.subtitle: "Outil de compatibilité VRChat", .about: "À propos", .done: "Terminé", .safetyBody: "L’app officielle reste intacte. Une copie et une bibliothèque séparées sont créées.", .dropTitle: "Déposez PlayCover.app", .dropSubtitle: "ou choisissez l’app officielle", .choose: "Choisir PlayCover…", .remove: "Supprimer la copie", .inspect: "Vérifier", .repair: "Réparer", .create: "Créer une copie", .activity: "Activité", .cancel: "Annuler", .ok: "OK", .removeConfirmTitle: "Supprimer PlayCover VRChat ?", .removeConfirmMessage: "Seule l’app patchée est supprimée. L’app officielle et les données restent.", .notInspected: "Déposez PlayCover.app", .originalMissing: "PlayCover introuvable", .vrChatMissing: "VRChat introuvable", .ready: "Prêt", .controllerRequired: "Installer le composant", .installed: "Prêt à jouer", .repairRequired: "Réparation requise", .unsupportedRuntime: "Mac non pris en charge", .applicationsRunning: "Fermez les apps", .unknownModification: "Modifications inconnues", .sourceOnly: "Version développeur", .notInspectedDetail: "Déposez l’app officielle pour commencer.", .originalMissingDetail: "Choisissez PlayCover officiel.", .vrChatMissingDetail: "Installez d’abord la version compatible de VRChat : %@", .readyDetail: "L’app officielle est vérifiée et ne sera pas modifiée.", .controllerRequiredDetail: "Installez le composant pour continuer. (%@)", .installedDetail: "Prêt. Réglez la mémoire dans les réglages de VRChat.", .repairDetail: "Terminez l’installation interrompue.", .applicationsRunningDetail: "Fermez %@ puis réessayez.", .selectedLog: "%@ sélectionné", .inspectionLog: "État : %@", .inspectionFailedLog: "Échec de la vérification", .operationCreate: "Création de la copie", .operationRepair: "Réparation", .operationRemove: "Suppression de la copie", .operationCompleteLog: "Terminé : %@", .operationStoppedLog: "Arrêt sécurisé", .independentLibraryLog: "Bibliothèque : %@"],
        .german: [.subtitle: "VRChat-Kompatibilitätstool", .about: "Über", .done: "Fertig", .safetyBody: "Die offizielle App bleibt unverändert. Eine separate Kopie und Spielebibliothek werden erstellt.", .dropTitle: "PlayCover.app ablegen", .dropSubtitle: "oder offizielle App auswählen", .choose: "PlayCover auswählen…", .remove: "Kopie entfernen", .inspect: "Prüfen", .repair: "Reparieren", .create: "Kopie erstellen", .activity: "Aktivität", .cancel: "Abbrechen", .ok: "OK", .removeConfirmTitle: "PlayCover VRChat entfernen?", .removeConfirmMessage: "Nur die gepatchte App wird entfernt. Offizielle App und Daten bleiben erhalten.", .notInspected: "PlayCover.app ablegen", .originalMissing: "PlayCover nicht gefunden", .vrChatMissing: "VRChat nicht gefunden", .ready: "Bereit", .controllerRequired: "Komponente installieren", .installed: "Spielbereit", .repairRequired: "Reparatur nötig", .unsupportedRuntime: "Mac nicht unterstützt", .applicationsRunning: "Apps schließen", .unknownModification: "Unbekannte Änderungen", .sourceOnly: "Entwicklerversion", .notInspectedDetail: "Offizielle App ablegen, um zu beginnen.", .originalMissingDetail: "Offizielles PlayCover auswählen.", .vrChatMissingDetail: "Unterstützte VRChat-Version installieren: %@", .readyDetail: "Offizielle App geprüft. Sie wird nicht geändert.", .controllerRequiredDetail: "Komponente installieren, um fortzufahren. (%@)", .installedDetail: "Bereit. Speicher in den VRChat-App-Einstellungen anpassen.", .repairDetail: "Unterbrochene Installation abschließen.", .applicationsRunningDetail: "%@ schließen und erneut prüfen.", .selectedLog: "%@ ausgewählt", .inspectionLog: "Status: %@", .inspectionFailedLog: "Prüfung fehlgeschlagen", .operationCreate: "Kopie wird erstellt", .operationRepair: "Reparatur", .operationRemove: "Kopie wird entfernt", .operationCompleteLog: "Fertig: %@", .operationStoppedLog: "Sicher angehalten", .independentLibraryLog: "Spielebibliothek: %@"],
        .russian: [.subtitle: "Инструмент совместимости VRChat", .about: "О программе", .done: "Готово", .safetyBody: "Официальное приложение не изменяется. Создаются отдельная копия и библиотека игры.", .dropTitle: "Перетащите PlayCover.app", .dropSubtitle: "или выберите официальное приложение", .choose: "Выбрать PlayCover…", .remove: "Удалить копию", .inspect: "Проверить", .repair: "Восстановить", .create: "Создать копию", .activity: "Активность", .cancel: "Отмена", .ok: "ОК", .removeConfirmTitle: "Удалить PlayCover VRChat?", .removeConfirmMessage: "Будет удалено только пропатченное приложение. Официальное приложение и данные сохранятся.", .notInspected: "Перетащите PlayCover.app", .originalMissing: "PlayCover не найден", .vrChatMissing: "VRChat не найден", .ready: "Готово", .controllerRequired: "Установить компонент", .installed: "Готово к запуску", .repairRequired: "Нужно восстановление", .unsupportedRuntime: "Mac не поддерживается", .applicationsRunning: "Закройте приложения", .unknownModification: "Неизвестные изменения", .sourceOnly: "Версия разработчика", .notInspectedDetail: "Перетащите официальное приложение.", .originalMissingDetail: "Выберите официальный PlayCover.", .vrChatMissingDetail: "Сначала установите поддерживаемую версию VRChat: %@", .readyDetail: "Официальное приложение проверено и не будет изменено.", .controllerRequiredDetail: "Установите компонент для продолжения. (%@)", .installedDetail: "Готово. Память настраивается в настройках VRChat.", .repairDetail: "Завершите прерванную установку.", .applicationsRunningDetail: "Закройте %@ и повторите проверку.", .selectedLog: "Выбрано: %@", .inspectionLog: "Статус: %@", .inspectionFailedLog: "Проверка не удалась", .operationCreate: "Создание копии", .operationRepair: "Восстановление", .operationRemove: "Удаление копии", .operationCompleteLog: "Готово: %@", .operationStoppedLog: "Безопасно остановлено", .independentLibraryLog: "Библиотека игры: %@"],
        .portuguese: [.subtitle: "Ferramenta de compatibilidade do VRChat", .about: "Sobre", .done: "Concluído", .safetyBody: "O app oficial não é alterado. Uma cópia e uma biblioteca separadas são criadas.", .dropTitle: "Solte o PlayCover.app", .dropSubtitle: "ou escolha o app oficial", .choose: "Escolher PlayCover…", .remove: "Remover cópia", .inspect: "Verificar", .repair: "Reparar", .create: "Criar cópia", .activity: "Atividade", .cancel: "Cancelar", .ok: "OK", .removeConfirmTitle: "Remover o PlayCover VRChat?", .removeConfirmMessage: "Somente o app corrigido será removido. O app oficial e os dados permanecem.", .notInspected: "Solte o PlayCover.app", .originalMissing: "PlayCover não encontrado", .vrChatMissing: "VRChat não encontrado", .ready: "Pronto", .controllerRequired: "Instalar componente", .installed: "Pronto para jogar", .repairRequired: "Reparo necessário", .unsupportedRuntime: "Mac não compatível", .applicationsRunning: "Feche os apps", .unknownModification: "Alterações desconhecidas", .sourceOnly: "Versão de desenvolvedor", .notInspectedDetail: "Solte o app oficial para começar.", .originalMissingDetail: "Escolha o PlayCover oficial.", .vrChatMissingDetail: "Instale primeiro a versão compatível do VRChat: %@", .readyDetail: "O app oficial foi verificado e não será alterado.", .controllerRequiredDetail: "Instale o componente para continuar. (%@)", .installedDetail: "Pronto. Ajuste a memória nos ajustes do VRChat.", .repairDetail: "Conclua a instalação interrompida.", .applicationsRunningDetail: "Feche %@ e verifique novamente.", .selectedLog: "%@ selecionado", .inspectionLog: "Status: %@", .inspectionFailedLog: "Falha na verificação", .operationCreate: "Criando cópia", .operationRepair: "Reparando", .operationRemove: "Removendo cópia", .operationCompleteLog: "Concluído: %@", .operationStoppedLog: "Parado com segurança", .independentLibraryLog: "Biblioteca: %@"],
        .vietnamese: [.subtitle: "Công cụ tương thích VRChat", .about: "Giới thiệu", .done: "Xong", .safetyBody: "Ứng dụng chính thức không bị thay đổi. Công cụ tạo bản PlayCover VRChat và thư viện riêng.", .dropTitle: "Thả PlayCover.app", .dropSubtitle: "hoặc chọn ứng dụng chính thức", .choose: "Chọn PlayCover…", .remove: "Xóa bản sao", .inspect: "Kiểm tra", .repair: "Sửa chữa", .create: "Tạo bản sao", .activity: "Hoạt động", .cancel: "Hủy", .ok: "OK", .removeConfirmTitle: "Xóa PlayCover VRChat?", .removeConfirmMessage: "Chỉ bản đã vá bị xóa. Ứng dụng chính thức và dữ liệu vẫn giữ nguyên.", .notInspected: "Thả PlayCover.app", .originalMissing: "Không tìm thấy PlayCover", .vrChatMissing: "Không tìm thấy VRChat", .ready: "Sẵn sàng", .controllerRequired: "Cài thành phần", .installed: "Sẵn sàng chơi", .repairRequired: "Cần sửa", .unsupportedRuntime: "Mac không được hỗ trợ", .applicationsRunning: "Đóng ứng dụng", .unknownModification: "Thay đổi không xác định", .sourceOnly: "Bản dành cho nhà phát triển", .notInspectedDetail: "Thả ứng dụng chính thức để bắt đầu.", .originalMissingDetail: "Chọn PlayCover chính thức.", .vrChatMissingDetail: "Cài VRChat được hỗ trợ trước: %@", .readyDetail: "Ứng dụng chính thức đã xác minh và sẽ không bị sửa.", .controllerRequiredDetail: "Cài thành phần để tiếp tục. (%@)", .installedDetail: "Sẵn sàng. Điều chỉnh bộ nhớ trong cài đặt VRChat.", .repairDetail: "Hoàn tất cài đặt bị gián đoạn.", .applicationsRunningDetail: "Đóng %@ rồi kiểm tra lại.", .selectedLog: "Đã chọn %@", .inspectionLog: "Trạng thái: %@", .inspectionFailedLog: "Kiểm tra thất bại", .operationCreate: "Đang tạo bản sao", .operationRepair: "Đang sửa", .operationRemove: "Đang xóa bản sao", .operationCompleteLog: "Hoàn tất: %@", .operationStoppedLog: "Đã dừng an toàn", .independentLibraryLog: "Thư viện: %@"]
    ]

    static func text(_ key: Key) -> String {
        translations[language]?[key] ?? english[key] ?? key.rawValue
    }

    static func format(_ key: Key, _ values: CVarArg...) -> String {
        String(format: text(key), arguments: values)
    }

    // Kept for core error messages and compatibility with older call sites.
    static func text(_ englishText: String, _ chineseText: String) -> String {
        switch language {
        case .simplifiedChinese: return chineseText
        default: return englishText
        }
    }
}
