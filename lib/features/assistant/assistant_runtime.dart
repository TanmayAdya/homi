import 'assistant_model.dart';
import 'local_assistant_model.dart';

const localAssistantTrial = bool.fromEnvironment('HOMI_LLAMA_TRIAL');
AssistantModel assistantRuntime() => localAssistantTrial
    ? const LocalAssistantModel()
    : const OnDeviceAssistantModel();
