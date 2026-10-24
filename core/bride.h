#pragma once

#include <stdlib.h>

extern void (*release_object_func)(void *obj);

extern void (*free_string_func)(char *data);

extern int (*protect_func)(void *tun_interface, int fd);

extern int (*resolve_uid_func)(void *tun_interface, int protocol, const char *source, const char *target);

extern char* (*resolve_package_func)(void *tun_interface, int uid);

// Answers the platform's own machine id and system name. Android keeps both
// behind Java APIs (Settings.Secure.ANDROID_ID, Build.VERSION), so the JNI
// layer reads them and hands them over; the core then derives the directory
// id from them instead of taking one written into the shared profile.
extern char* (*machine_id_func)(void);
extern char* (*os_name_func)(void);

// An empty string when the platform cannot answer - never a made-up id.
extern char* machine_id(void);
extern char* os_name(void);

extern void (*result_func)(void *invoke_Interface, const char *data);

extern int protect(void *tun_interface, int fd);

// Returns -1 when the system will not name the owner of the connection.
extern int resolve_uid(void *tun_interface, int protocol, const char *source, const char *target);

extern char* resolve_package(void *tun_interface, int uid);

extern void release_object(void *obj);

extern void free_string(char *data);

extern void result(void *invoke_Interface,  const char *data);