import 'package:c4_tools/main.dart' show MainApp;
import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:c4_tools/services/app_settings.dart';
import 'package:flutter/material.dart';
import '../models/jailbreak_step.dart';
import 'dart:async';
import '../models/ssh_jailbreak.dart';
import '../models/certificate_patch.dart';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';

class JailbreakScreen extends StatefulWidget {
  final String directorIP;
  final String? jwtToken;
  final String? directorVersion;

  const JailbreakScreen({
    Key? key,
    required this.directorIP,
    required this.jwtToken,
    required this.directorVersion,
  }) : super(key: key);

  @override
  State<JailbreakScreen> createState() => _JailbreakScreenState();
}

class _JailbreakScreenState extends State<JailbreakScreen> {
  bool _isRunning = false;
  bool _isCancelRequested = false;
  late final SSHJailbreak _jailbreak;
  late final CertificatePatch _certPatch;
  late final List<JailbreakStep> _steps;
  bool _patchComposer = Platform.isWindows;
  bool _patchDirector = Platform.isWindows;
  bool _enableSSH = true;
  bool _sshAlreadyEnabled = false;
  bool _checkingSSH = false;

  @override
  void initState() {
    super.initState();
    appLogger.i('\n=== Initializing Jailbreak Screen ===');

    _jailbreak = SSHJailbreak(
      directorIP: widget.directorIP,
      jwtToken: widget.jwtToken,
      updateStepStatus: _updateStepStatus,
      directorVersion: widget.directorVersion,
    );

    _certPatch = CertificatePatch(
      directorIP: widget.directorIP,
      jwtToken: widget.jwtToken,
      updateStepStatus: _updateStepStatus,
    );
    _certPatch.context = context;

    final certSteps = _certPatch.createSteps();
    final sshSteps = _jailbreak.createSteps();

    // Add cancellation check to all steps
    for (var step in [...certSteps, ...sshSteps]) {
      step.checkCancellation = () => _isCancelRequested;
    }

    _steps = [...certSteps, ...sshSteps];

    _checkSSHStatus();
  }

  Future<void> _checkSSHStatus() async {
    if (mounted) {
      setState(() {
        _checkingSSH = true;
      });
    }

    try {
      appLogger.i('Checking if SSH is already enabled...');
      final socket = await SSHSocket.connect(widget.directorIP, 22,
              timeout: const Duration(seconds: 3))
          .timeout(const Duration(seconds: 5));

      final client = SSHClient(
        socket,
        username: 'root',
        onPasswordRequest: () => 't0talc0ntr0l4!',
      );

      // Try to verify existing connection
      try {
        final session = await client.shell(
          pty: SSHPtyConfig(
            width: 80,
            height: 24,
          ),
        );

        session.close();
        appLogger.i('SSH is already enabled and accessible');

        if (mounted) {
          setState(() {
            _enableSSH = false;
            _sshAlreadyEnabled = true;
          });
        }
      } catch (e) {
        appLogger.w('SSH connection established but shell failed: $e');
      } finally {
        client.close();
        socket.close();
      }
    } catch (e) {
      appLogger.w('SSH is not enabled or not accessible: $e');
    } finally {
      if (mounted) {
        setState(() {
          _checkingSSH = false;
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Apparently we need to update the context when dependencies change
    _certPatch.context = context;
  }

  Future<void> _startJailbreak() async {
    appLogger.i('\n=== Starting Jailbreak Process ===');
    if (widget.jwtToken == null) {
      appLogger.e('Error: No JWT token provided');
      MainApp.showSnackBar('Please authenticate with the director first',
          isError: true);
      return;
    }

    setState(() {
      _isCancelRequested = false;
    });

    final List<JailbreakStep> stepsToRun = [];
    for (var step in _steps) {
      switch (step.type) {
        case StepType.composer:
          if (!_patchComposer) {
            continue;
          }
          break;
        case StepType.ssh:
          if (_sshAlreadyEnabled || !_enableSSH) {
            continue;
          }
          break;
        case StepType.director:
          if (!_patchDirector) {
            continue;
          }
          break;
      }
      stepsToRun.add(step);
    }

    appLogger
        .t('Steps to run: ${stepsToRun.map((step) => step.title).join(', ')}');

    if (stepsToRun.isEmpty) {
      MainApp.showSnackBar('Please select at least one phase to run',
          isError: true);
      return;
    }

    appLogger.t('\nResetting all steps to pending');
    setState(() {
      _isRunning = true;
      for (var step in _steps) {
        step.status = StepStatus.pending;
        step.currentSubStep = null;
      }
    });

    try {
      appLogger.i('\n=== Executing Steps ===');
      for (var i = 0; i < stepsToRun.length; i++) {
        // Check if cancellation was requested
        if (_isCancelRequested) {
          appLogger.w('Jailbreak cancelled by user');
          MainApp.showSnackBar('Jailbreak cancelled by user', isError: true);
          return;
        }

        final step = stepsToRun[i];
        final originalIndex = _steps.indexOf(step);

        appLogger.t('\nExecuting step $originalIndex: "${step.title}"');
        appLogger.t('Current step status: ${step.status}');

        appLogger.t('Updating step status to running');
        await _updateStepStatus(originalIndex, StepStatus.running);
        appLogger.t('Step status updated');

        appLogger.t('Calling step.execute($originalIndex)');
        final success = await step.execute(originalIndex);
        appLogger.d('Step execution completed with result: $success');

        // If the step was cancelled by the user, stop the jailbreak
        if (success == null) {
          appLogger.w('Step "${step.title}" was cancelled by user');
          await _updateStepStatus(
              originalIndex, StepStatus.failed, 'Cancelled by user');
          MainApp.showSnackBar('Jailbreak cancelled by user', isError: true);
          return;
        }

        // If the step failed, stop the jailbreak
        if (!success) {
          appLogger.e('Step "${step.title}" failed');
          await _updateStepStatus(
              originalIndex, StepStatus.failed, step.currentSubStep);
          MainApp.showSnackBar(
              'Jailbreak failed: ${step.currentSubStep ?? "Unknown error"}',
              isError: true);
          return;
        }

        // Verify the step is complete before moving on
        if (_steps[originalIndex].status != StepStatus.completed) {
          appLogger.i('Marking step as completed');
          await _updateStepStatus(originalIndex, StepStatus.completed);
        }

        appLogger.t('Waiting for UI update...');
        await Future.delayed(const Duration(milliseconds: 500));
      }

      appLogger.i('\nJailbreak completed successfully!');
      MainApp.showSnackBar('Success!');

      if (_patchDirector) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Reboot Director?'),
              content: const Text(
                'All steps completed successfully. Would you like to reboot the Director now to apply all the changes?',
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('No'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
                TextButton(
                  child: const Text('Yes, Reboot'),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await _rebootDirector();
                  },
                ),
              ],
            );
          },
        );
      }
    } catch (e, stackTrace) {
      appLogger.e('\nError during jailbreak.',
          error: e, stackTrace: stackTrace);
      // Don't clear the log, just show the error
      MainApp.showSnackBar('Jailbreak failed: $e', isError: true);
    } finally {
      appLogger.i('\nSetting _isRunning to false');
      setState(() {
        _isRunning = false;
        _isCancelRequested = false;
      });
    }
  }

  Future<void> _updateStepStatus(int index, StepStatus status,
      [String? subStep]) async {
    appLogger.d('\nUpdating step status:');
    appLogger.d('SubStep: $subStep');

    if (index < 0 || index >= _steps.length) {
      appLogger.e('ERROR: Invalid step index!');
      for (var i = 0; i < _steps.length; i++) {
        appLogger.d('$i: ${_steps[i].title}');
      }
      throw Exception('Invalid step index: $index');
    }

    setState(() {
      _steps[index].status = status;
      _steps[index].currentSubStep = subStep;
    });
    appLogger.d('Status updated successfully');

    await Future.delayed(const Duration(milliseconds: 100));
  }

  void _showConfirmationDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Start Jailbreak?'),
          content: Text(
            'This may modify your Control4 system. Are you sure you want to proceed?',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Start'),
              onPressed: () {
                Navigator.of(context).pop();
                _startJailbreak();
              },
            ),
          ],
        );
      },
    );
  }

  void _showCancelConfirmationDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Cancel Jailbreak?'),
          content: const Text(
            'This will stop the current and any future steps. Are you sure you want to cancel?',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('No, Continue'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Yes, Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
                setState(() {
                  _isCancelRequested = true;
                });
                appLogger.i('Jailbreak cancellation requested by user');
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('One-Click Jailbreak'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_isRunning)
            IconButton(
              icon: const Icon(Icons.cancel),
              tooltip: 'Cancel Jailbreak',
              onPressed: _showCancelConfirmationDialog,
            ),
        ],
      ),
      body: Center(
        child: Column(
          children: [
            // Add checkboxes section
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'Phases:',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _buildPhaseCheckbox(
                        label: 'Patch Composer',
                        value: _patchComposer,
                        onChanged: !Platform.isWindows
                            ? null
                            : (val) =>
                                setState(() => _patchComposer = val ?? false),
                      ),
                      _buildPhaseCheckbox(
                        label: 'Reset SSH',
                        value: _enableSSH,
                        onChanged: (val) =>
                            setState(() => _enableSSH = val ?? false),
                      ),
                      _buildPhaseCheckbox(
                        label: 'Patch Director',
                        value: _patchDirector,
                        onChanged: !Platform.isWindows
                            ? null
                            : (val) =>
                                setState(() => _patchDirector = val ?? false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 1,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 200,
                    maxHeight: 200,
                  ),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: _isRunning
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 40,
                                height: 40,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                onPressed: _showCancelConfirmationDialog,
                                icon: const Icon(Icons.cancel, size: 16),
                                label: const Text('Cancel'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ],
                          )
                        : ElevatedButton(
                            onPressed:
                                _isRunning ? null : _showConfirmationDialog,
                            style: ElevatedButton.styleFrom(
                              shape: const CircleBorder(),
                              padding: const EdgeInsets.all(40),
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.onPrimary,
                            ),
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.lock_open, size: 40),
                                SizedBox(height: 8),
                                Text(
                                  'Start\nJailbreak',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 16),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                    color: theme.cardColor,
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                        decoration: BoxDecoration(
                          color: isDark
                              ? theme.cardColor
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(8),
                            topRight: Radius.circular(8),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.list_alt,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Jailbreak Log',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.description, size: 16),
                              onPressed: AppSettings.instance.openLogFile,
                              tooltip: 'Open Log File',
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(8),
                          child: _buildLogText(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogText() {
    // Check if any steps have been executed
    final hasExecutedSteps =
        _steps.any((step) => step.status != StepStatus.pending);

    if (!hasExecutedSteps) {
      return SelectableText(
        'Ready to start...',
        style: TextStyle(
          fontFamily: 'monospace',
          color: Theme.of(context).colorScheme.onSurface,
        ),
      );
    }

    final List<Widget> logLines = [];
    for (var i = 0; i < _steps.length; i++) {
      final step = _steps[i];
      if (step.status != StepStatus.pending) {
        final statusIcon = _getStatusIcon(step.status);
        final stepText = 'Step ${i + 1}: ${step.title}';

        // Add the main step line
        logLines.add(
          SelectableText.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$statusIcon ',
                  style: TextStyle(
                    color: step.status == StepStatus.completed
                        ? Colors.green
                        : step.status == StepStatus.failed
                            ? Colors.red
                            : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                TextSpan(
                  text: stepText,
                  style: TextStyle(
                    color: step.status == StepStatus.completed
                        ? Colors.green
                        : step.status == StepStatus.failed
                            ? Colors.red
                            : Theme.of(context).colorScheme.onSurface,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        );

        if (step.currentSubStep != null) {
          // For non-failed steps, show the substep with the appropriate color
          if (step.status != StepStatus.failed) {
            logLines.add(
              SelectableText.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '   → ',
                      style: TextStyle(
                        color: step.status == StepStatus.completed
                            ? Colors.green
                            : Colors.yellow,
                      ),
                    ),
                    TextSpan(
                      text: step.currentSubStep!,
                      style: TextStyle(
                        color: step.status == StepStatus.completed
                            ? Colors.green
                            : Colors.yellow,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          // For failed steps, highlight the substep
          else {
            logLines.add(
              SelectableText.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '   ✗ ',
                      style: const TextStyle(
                        color: Colors.red,
                      ),
                    ),
                    TextSpan(
                      text: step.currentSubStep!,
                      style: TextStyle(
                        color: Colors.red,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: logLines,
    );
  }

  String _getStatusIcon(StepStatus status) {
    switch (status) {
      case StepStatus.pending:
        return '○';
      case StepStatus.running:
        return '⟳';
      case StepStatus.completed:
        return '✓';
      case StepStatus.failed:
        return '✗';
    }
  }

  Future<void> _rebootDirector() async {
    try {
      appLogger.i('\nRebooting Director at ${widget.directorIP}...');

      if (mounted) {
        MainApp.showSnackBar('Rebooting Director...');
      }

      final socket = await SSHSocket.connect(widget.directorIP, 22,
          timeout: const Duration(seconds: 5));

      final client = SSHClient(
        socket,
        username: 'root',
        onPasswordRequest: () => 't0talc0ntr0l4!',
      );

      try {
        await client.run('reboot');
        appLogger.i('Reboot command sent successfully');

        if (mounted) {
          showDialog<void>(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                title: const Text('Rebooting Director...'),
                content: const Text('The Director is rebooting. ' +
                    'Please wait a few minutes before connecting with Composer Pro.'),
                actions: <Widget>[
                  TextButton(
                    child: const Text('OK'),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              );
            },
          );
        }
      } catch (e) {
        appLogger.e('Error sending reboot command: $e');
        if (mounted) {
          MainApp.showSnackBar('Failed to send reboot command: $e',
              isError: true);
        }
      } finally {
        client.close();
        socket.close();
      }
    } catch (e) {
      appLogger.e('Failed to connect to Director for reboot: $e');
      if (mounted) {
        MainApp.showSnackBar('Failed to connect to Director: $e',
            isError: true);
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Widget _buildPhaseCheckbox({
    required String label,
    required bool value,
    required ValueChanged<bool?>? onChanged,
  }) {
    // Special case for SSH checkbox when SSH is already enabled
    if (label == 'Reset SSH' && _sshAlreadyEnabled) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'SSH already enabled',
            child: Checkbox(
              value: false,
              onChanged: null,
            ),
          ),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // Show loading indicator while checking SSH
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            onChanged == null
                ? Tooltip(
                    message: 'Only available on Windows',
                    child: Checkbox(value: value, onChanged: onChanged),
                  )
                : Checkbox(value: value, onChanged: onChanged),
            if (label == 'Reset SSH' && _checkingSSH) ...[
              Positioned(
                left: 0,
                top: 0,
                child: Container(
                  width: 40,
                  height: 40,
                  color: Colors.black.withValues(alpha: 0.5),
                  padding: const EdgeInsets.all(2.0),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                ),
              ),
            ],
          ],
        ),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
