#ifndef HOMI_LLM_H
#define HOMI_LLM_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
enum homi_llm_code {
  HOMI_OK = 0, HOMI_INVALID_INPUT = 1, HOMI_BUSY = 2,
  HOMI_CANCELLED = 3, HOMI_MODEL_MISSING = 4, HOMI_INVALID_MODEL = 5,
  HOMI_CONTEXT_LIMIT = 6, HOMI_FAILED = 7, HOMI_UNSUPPORTED = 8
};
struct homi_llm_metrics {
  double first_token_ms;
  double total_ms;
  int prompt_tokens;
  int output_tokens;
};
// Generate into a caller-owned buffer of at least 9601 bytes
int homi_llm_generate(const char *request_id, const char *model_path,
                     const char *system_prompt, const char *prompt, int use_gpu,
                     char *output, size_t capacity, struct homi_llm_metrics *metrics);
void homi_llm_cancel(const char *request_id);
// Unload idle state or return BUSY while a worker runs
int homi_llm_unload(void);
int homi_llm_busy(void);
const char *homi_llm_runtime_id(void);
#ifdef __cplusplus
}
#endif
#endif
