#include <jni.h>
#include <string>
#include "../../../../native/homi_llm.h"
static std::string bytes(JNIEnv *env, jbyteArray input) {
  if (!input || env->GetArrayLength(input) > 20000) return {};
  std::string value((size_t)env->GetArrayLength(input), '\0');
  env->GetByteArrayRegion(input, 0, (jsize)value.size(), reinterpret_cast<jbyte *>(value.data()));
  return value;
}
extern "C" JNIEXPORT jint JNICALL
Java_org_safeathome_homi_1local_1llm_LocalNative_generate(JNIEnv *env, jobject,
    jbyteArray id, jbyteArray path, jbyteArray system, jbyteArray prompt,
    jbyteArray output, jdoubleArray stats) {
  if (!output || env->GetArrayLength(output) != 9601 || !stats || env->GetArrayLength(stats) != 4) return HOMI_INVALID_INPUT;
  const auto i = bytes(env, id), p = bytes(env, path), s = bytes(env, system), q = bytes(env, prompt);
  if (i.find('\0') != std::string::npos || p.find('\0') != std::string::npos || s.find('\0') != std::string::npos || q.find('\0') != std::string::npos) return HOMI_INVALID_INPUT;
  char text[9601] = {}; homi_llm_metrics metrics = {};
  const int code = homi_llm_generate(i.c_str(), p.c_str(), s.c_str(), q.c_str(), 0, text, sizeof(text), &metrics);
  if (code == HOMI_OK) {
    env->SetByteArrayRegion(output, 0, sizeof(text), reinterpret_cast<jbyte *>(text));
    const jdouble values[] = {metrics.first_token_ms, metrics.total_ms, (double)metrics.prompt_tokens, (double)metrics.output_tokens};
    env->SetDoubleArrayRegion(stats, 0, 4, values);
  }
  return code;
}
extern "C" JNIEXPORT void JNICALL
Java_org_safeathome_homi_1local_1llm_LocalNative_cancel(JNIEnv *env, jobject, jbyteArray id) {
  const auto value = bytes(env, id); homi_llm_cancel(value.c_str());
}
extern "C" JNIEXPORT jint JNICALL
Java_org_safeathome_homi_1local_1llm_LocalNative_unload(JNIEnv *, jobject) { return homi_llm_unload(); }
