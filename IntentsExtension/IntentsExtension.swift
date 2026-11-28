import AppIntents
import Library

@main
struct IntentsExtension: AppIntentsExtension {
    init() {
        #if os(iOS) && !JAILBREAK
        AppConfiguration.recordExtensionGroupAccess()
        #endif
    }
}
