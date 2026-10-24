#include <jni.h>

#include <cstdlib>
#include <cstring>
#include <string>

#include "jni_helper.h"
#include "libclash.h"
#include "bride.h"

extern "C"
JNIEXPORT jboolean JNICALL
Java_com_follow_clash_core_Core_startTun(JNIEnv *env, jobject thiz, jint fd, jobject cb,
                                         jstring stack, jstring address, jstring dns) {
    const auto interface = new_global(cb);
    return startTUN(interface, fd, get_string(stack), get_string(address), get_string(dns))
           ? JNI_TRUE
           : JNI_FALSE;
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clash_core_Core_stopTun(JNIEnv *env, jobject thiz) {
    stopTun();
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clash_core_Core_forceGC(JNIEnv *env, jobject thiz) {
    forceGC();
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clash_core_Core_updateDNS(JNIEnv *env, jobject thiz, jstring dns) {
    updateDns(get_string(dns));
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clash_core_Core_invokeMethod(JNIEnv *env, jobject thiz, jstring data, jobject cb) {
    const auto interface = new_global(cb);
    invokeMethod(interface, get_string(data));
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clash_core_Core_setEventListener(JNIEnv *env, jobject thiz, jobject cb) {
    if (cb != nullptr) {
        const auto interface = new_global(cb);
        setEventListener(interface);
    } else {
        setEventListener(nullptr);
    }
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_follow_clash_core_Core_getTraffic(JNIEnv *env, jobject thiz,
                                           const jboolean only_statistics_proxy) {
    scoped_string traffic = getTraffic(only_statistics_proxy);
    return new_string(traffic);
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_follow_clash_core_Core_getTotalTraffic(JNIEnv *env, jobject thiz,
                                                const jboolean only_statistics_proxy) {
    scoped_string traffic = getTotalTraffic(only_statistics_proxy);
    return new_string(traffic);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clash_core_Core_suspended(JNIEnv *env, jobject thiz, jboolean suspended) {
    suspend(suspended);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_follow_clash_core_Core_quickSetup(JNIEnv *env, jobject thiz, jstring init_params_string,
                                           jstring setup_params_string, jobject cb) {
    const auto interface = new_global(cb);
    quickSetup(interface, get_string(init_params_string), get_string(setup_params_string));
}


static jmethodID m_tun_interface_protect;
static jmethodID m_tun_interface_resolve_uid;
static jmethodID m_tun_interface_resolve_package;
static jmethodID m_invoke_interface_result;


static void release_jni_object_impl(void *obj) {
    ATTACH_JNI();
    del_global(static_cast<jobject>(obj));
}

static void free_string_impl(char *str) {
    free(str);
}

static int call_tun_interface_protect_impl(void *tun_interface, const int fd) {
    // ART aborts the process on a call through a null object, so a callback
    // that was already released has to stop here rather than at the JNI call.
    if (tun_interface == nullptr) {
        return 0;
    }
    ATTACH_JNI();
    const auto accepted = env->CallBooleanMethod(static_cast<jobject>(tun_interface),
                                                 m_tun_interface_protect,
                                                 fd);
    if (jni_clear_exception(env)) {
        return 0;
    }
    return accepted == JNI_TRUE ? 1 : 0;
}

static int call_tun_interface_resolve_uid_impl(void *tun_interface, const int protocol,
                                               const char *source,
                                               const char *target) {
    if (tun_interface == nullptr) {
        return -1;
    }
    ATTACH_JNI();
    const auto source_string = new_string(source);
    const auto target_string = new_string(target);
    const auto uid = env->CallIntMethod(static_cast<jobject>(tun_interface),
                                        m_tun_interface_resolve_uid,
                                        protocol,
                                        source_string,
                                        target_string);
    const auto failed = jni_clear_exception(env);
    if (source_string != nullptr) {
        env->DeleteLocalRef(source_string);
    }
    if (target_string != nullptr) {
        env->DeleteLocalRef(target_string);
    }
    return failed ? -1 : uid;
}

static char *call_tun_interface_resolve_package_impl(void *tun_interface, const int uid) {
    if (tun_interface == nullptr) {
        return strdup("");
    }
    ATTACH_JNI();
    const auto package_name = reinterpret_cast<jstring>(env->CallObjectMethod(
            static_cast<jobject>(tun_interface),
            m_tun_interface_resolve_package,
            uid));
    jni_clear_exception(env);
    const auto result = get_string(package_name);
    if (package_name != nullptr) {
        env->DeleteLocalRef(package_name);
    }
    return result;
}

static void call_invoke_interface_result_impl(void *invoke_interface, const char *data) {
    if (invoke_interface == nullptr) {
        return;
    }
    ATTACH_JNI();
    const auto value = new_string(data);
    env->CallVoidMethod(static_cast<jobject>(invoke_interface),
                        m_invoke_interface_result,
                        value);
    jni_clear_exception(env);
    if (value != nullptr) {
        env->DeleteLocalRef(value);
    }
}

static char *empty_c_string() {
    return static_cast<char *>(calloc(1, 1));
}

// ANDROID_ID, read through the platform's own API: it lives behind
// Settings.Secure, and no file in the app sandbox holds it. The Application is
// reached through ActivityThread because this process was started by Flutter
// and never handed a Context - the same object the app itself would use.
static char *read_machine_id_impl() {
    ATTACH_JNI();
    const auto activity_thread = find_class("android/app/ActivityThread");
    if (activity_thread == nullptr || jni_clear_exception(env)) {
        return empty_c_string();
    }
    const auto current_application = env->GetStaticMethodID(
        activity_thread, "currentApplication", "()Landroid/app/Application;");
    if (current_application == nullptr || jni_clear_exception(env)) {
        return empty_c_string();
    }
    const auto application = env->CallStaticObjectMethod(activity_thread, current_application);
    if (application == nullptr || jni_clear_exception(env)) {
        return empty_c_string();
    }

    const auto context = find_class("android/content/Context");
    const auto get_resolver = find_method(context, "getContentResolver",
                                          "()Landroid/content/ContentResolver;");
    const auto resolver = env->CallObjectMethod(application, get_resolver);
    if (resolver == nullptr || jni_clear_exception(env)) {
        env->DeleteLocalRef(application);
        return empty_c_string();
    }

    const auto secure = find_class("android/provider/Settings$Secure");
    const auto get_string_method = env->GetStaticMethodID(
        secure, "getString",
        "(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;");
    const auto key = new_string("android_id");
    const auto value = static_cast<jstring>(env->CallStaticObjectMethod(
        secure, get_string_method, resolver, key));

    env->DeleteLocalRef(key);
    env->DeleteLocalRef(resolver);
    env->DeleteLocalRef(application);

    if (value == nullptr || jni_clear_exception(env)) {
        return empty_c_string();
    }
    char *id = get_string(value);
    env->DeleteLocalRef(value);
    return id;
}

// "Android 14": Build.VERSION.RELEASE, the string the dashboard shows.
static char *read_os_name_impl() {
    ATTACH_JNI();
    const auto version = find_class("android/os/Build$VERSION");
    if (version == nullptr || jni_clear_exception(env)) {
        return empty_c_string();
    }
    const auto release_field = env->GetStaticFieldID(version, "RELEASE", "Ljava/lang/String;");
    if (release_field == nullptr || jni_clear_exception(env)) {
        return empty_c_string();
    }
    const auto release = static_cast<jstring>(env->GetStaticObjectField(version, release_field));
    if (release == nullptr || jni_clear_exception(env)) {
        return empty_c_string();
    }
    const auto release_text = get_string(release);
    env->DeleteLocalRef(release);

    std::string name = "Android";
    if (release_text != nullptr && release_text[0] != '\0') {
        name += " ";
        name += release_text;
    }
    free(release_text);

    auto *out = static_cast<char *>(malloc(name.size() + 1));
    if (out == nullptr) {
        return empty_c_string();
    }
    memcpy(out, name.c_str(), name.size() + 1);
    return out;
}

extern "C"
JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *) {
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    initialize_jni(vm, env);

    const auto c_tun_interface = find_class("com/follow/clash/core/TunInterface");

    const auto c_invoke_interface = find_class("com/follow/clash/core/InvokeInterface");

    m_tun_interface_protect = find_method(c_tun_interface, "protect", "(I)Z");
    m_tun_interface_resolve_uid = find_method(c_tun_interface, "resolveUid",
                                              "(ILjava/lang/String;Ljava/lang/String;)I");
    m_tun_interface_resolve_package = find_method(c_tun_interface, "resolvePackage",
                                                  "(I)Ljava/lang/String;");
    m_invoke_interface_result = find_method(c_invoke_interface, "onResult",
                                            "(Ljava/lang/String;)V");


    protect_func = &call_tun_interface_protect_impl;
    resolve_uid_func = &call_tun_interface_resolve_uid_impl;
    resolve_package_func = &call_tun_interface_resolve_package_impl;
    result_func = &call_invoke_interface_result_impl;
    release_object_func = &release_jni_object_impl;
    free_string_func = &free_string_impl;
    machine_id_func = &read_machine_id_impl;
    os_name_func = &read_os_name_impl;

    return JNI_VERSION_1_6;
}
