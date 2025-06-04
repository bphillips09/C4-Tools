import 'package:c4_tools/services/app_logger.dart' show appLogger;

enum StepStatus {
  pending,
  running,
  completed,
  failed,
}

typedef CancellationCheck = bool Function();

class JailbreakStep {
  final StepType type;
  final String title;
  final List<JailbreakSubStep> subSteps;
  StepStatus status;
  String? currentSubStep;
  final Function(int, StepStatus, [String?]) updateStepStatus;
  CancellationCheck? checkCancellation;

  JailbreakStep({
    required this.type,
    required this.title,
    required this.subSteps,
    required this.updateStepStatus,
    this.status = StepStatus.pending,
    this.currentSubStep,
    this.checkCancellation,
  });

  Future<bool?> execute(int stepIndex) async {
    appLogger.i('\n=== Executing ${title} Step ===');

    for (var i = 0; i < subSteps.length; i++) {
      if (checkCancellation != null && checkCancellation!()) {
        appLogger.w('Cancellation requested during step execution');
        return null; // Return null to indicate cancellation
      }

      final subStep = subSteps[i];
      appLogger.t('\nExecuting subStep $i: "${subStep.title}"');

      try {
        await updateStepStatus(stepIndex, StepStatus.running, subStep.title);
        appLogger.t('Updated status to running for subStep: ${subStep.title}');

        final success = await subStep.execute();
        appLogger.t('SubStep execution result: $success');

        if (!success) {
          appLogger.w('SubStep failed, marking step as failed');
          await updateStepStatus(
              stepIndex, StepStatus.failed, 'Failed: ${subStep.title}');
          return false;
        }
      } catch (e) {
        appLogger.e('Error executing subStep:', error: e);
        await updateStepStatus(
            stepIndex, StepStatus.failed, 'Error: ${e.toString()}');
        return false;
      }
    }

    appLogger.i('All subSteps completed successfully');
    await updateStepStatus(stepIndex, StepStatus.completed);
    return true;
  }
}

class SSHStep extends JailbreakStep {
  SSHStep({
    required super.title,
    required super.subSteps,
    required super.updateStepStatus,
  }) : super(type: StepType.ssh);
}

class ComposerStep extends JailbreakStep {
  ComposerStep({
    required super.title,
    required super.subSteps,
    required super.updateStepStatus,
  }) : super(type: StepType.composer);
}

class DirectorStep extends JailbreakStep {
  DirectorStep({
    required super.title,
    required super.subSteps,
    required super.updateStepStatus,
  }) : super(type: StepType.director);
}

class JailbreakSubStep {
  final String title;
  final String description;
  final Future<bool> Function() execute;

  JailbreakSubStep({
    required this.title,
    required this.description,
    required this.execute,
  });
}

enum StepType {
  composer,
  director,
  ssh,
}
