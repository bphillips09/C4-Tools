import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:c4_tools/widgets/framed_webview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';

class ComposerExpressScreen extends StatefulWidget {
  final String directorIP;
  final String? jwtToken;

  const ComposerExpressScreen({
    Key? key,
    required this.directorIP,
    required this.jwtToken,
  }) : super(key: key);

  @override
  State<ComposerExpressScreen> createState() => _ComposerExpressScreenState();
}

class _ComposerExpressScreenState extends State<ComposerExpressScreen> {
  late InAppWebViewController _webViewController;
  bool _isLoading = true;
  String? _indexPath;

  Future<String?> _getComposerExpressPath() async {
    final appDir = await getApplicationSupportDirectory();
    final composerPath = path.join(appDir.path, 'ComposerExpress');
    final indexPath = path.join(composerPath, 'assets', 'www', 'index.html');

    if (await File(indexPath).exists()) {
      if (Platform.isWindows) {
        // For Windows, use Uri.file to properly encode the path
        final uri = Uri.file(indexPath);
        return uri.toString();
      } else {
        // For non-Windows platforms, just prepend file://
        return 'file://$indexPath';
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _getComposerExpressPath().then((path) {
      setState(() {
        _indexPath = path;
      });
    });
  }

  void reload() {
    Navigator.of(context).pop();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ComposerExpressScreen(
          directorIP: widget.directorIP,
          jwtToken: widget.jwtToken,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_indexPath == null) {
      appLogger.w('Index path is null');
      return Scaffold(
        appBar: AppBar(
          title: const Text('Composer Express Error'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
        ),
        body: Center(
          child: Text('Waiting to load the WebView... Is it installed?'),
        ),
      );
    }

    appLogger.i('Loading URL: $_indexPath');

    return Stack(
      children: [
        FramedWebView(
          url: _indexPath ?? '',
          zoom: 1.0,
          showNavigationButtons: true,
          title: 'Composer Express',
          onWebViewCreated: (controller) {
            _webViewController = controller;
          },
          onReload: (controller) {
            reload();
          },
          onLoadStop: (controller, url) async {
            appLogger.d('onLoadStop: $url');

            final overrideScript = '''
              // Override the navigateToLogin function to include all initialization
              window.navigateToLogin = function() {
                // Set auth token
                wsSetAuthToken('${widget.jwtToken}');

                // Initialize socket.io if needed and connect to broker
                if (!window.io) {
                  const script = document.createElement('script');
                  script.src = 'https://cdn.socket.io/4.5.4/socket.io.min.js';
                  script.onload = initializeComposer;
                  document.head.appendChild(script);
                } else {
                  initializeComposer();
                }

                function initializeComposer() {
                  // Replace "tap Go" with "Submit/Enter"
                  function replaceText() {
                    const walker = document.createTreeWalker(
                      document.body, 
                      NodeFilter.SHOW_TEXT, 
                      null, 
                      false
                    );
                    
                    let node;
                    while(node = walker.nextNode()) {
                      if (node.nodeValue.includes('tap Go')) {
                        node.nodeValue = node.nodeValue.replace(/tap Go/g, 'Submit/Enter');
                      }
                    }
                  }
                  
                  // Run immediately
                  replaceText();
                  
                  // Also run when DOM changes
                  const observer = new MutationObserver(function(mutations) {
                    replaceText();
                  });
                  
                  observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    characterData: true
                  });

                  // Hide Tasks button and handle navigation
                  function hideTasksButton() {
                    const backButton = document.querySelector('a[href="#view_task_menu"]');
                    if (backButton) {
                      backButton.style.display = 'none';
                    }
                  }
                  
                  // Watch for navigation and handle accordingly
                  window.addEventListener('hashchange', function() {
                    if (window.location.hash === '#view_home') {
                      hideTasksButton();
                    } else if (window.location.hash === '#view_task_menu') {
                      // Prevent navigation to tasks menu by restoring previous hash
                      window.history.back();
                    }
                  });

                  // Override kendoMobileApplication.navigate to intercept task menu navigation
                  const originalNavigate = window.kendoMobileApplication.navigate;
                  window.kendoMobileApplication.navigate = function(hash) {
                    if (hash === '#view_task_menu') {
                      // Prevent navigation to tasks menu
                      return;
                    }
                    return originalNavigate.apply(this, arguments);
                  };

                  // Connect to broker
                  connectToBroker(
                    '${widget.directorIP}',
                    443,
                    'https',
                    '${widget.jwtToken}',
                    false
                  );
                }
              };
            ''';
            await _webViewController.evaluateJavascript(source: overrideScript);
          },
          onTitleChanged: (controller, title) {
            if (title == 'Project' ||
                title == 'Composer Express License Agreement') {
              setState(() {
                _isLoading = false;
              });
            } else if (title == 'Tasks') {
              //Something went wrong, we need to reload the Composer Express page
              showDialog(
                barrierDismissible: false,
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Composer Express Error'),
                  content: const Text(
                      'Composer Express has disconnected from the Director, please reload.'),
                  actions: [
                    TextButton(
                      child: const Text('Go Home'),
                      onPressed: () {
                        // Pop all screens until we reach Director Tools
                        Navigator.of(context)
                            .popUntil((route) => route.isFirst);
                      },
                    ),
                    TextButton(
                      child: const Text('Reload'),
                      onPressed: () {
                        // Pop the current screen
                        Navigator.of(context).pop();
                        reload();
                      },
                    ),
                  ],
                ),
              );
            }
          },
        ),
        if (_isLoading)
          Positioned.fill(
            top: kToolbarHeight,
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}
