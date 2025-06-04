import 'package:c4_tools/main.dart' show MainApp;
import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dart:collection';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

class FramedWebView extends StatefulWidget {
  final String url;
  final double zoom;
  final Function(InAppWebViewController)? onWebViewCreated;
  final Function(InAppWebViewController, Uri?)? onLoadStop;
  final Function(InAppWebViewController, Uri?)? onLoadStart;
  final Function(InAppWebViewController, String?)? onTitleChanged;
  final Function(InAppWebViewController)? onReload;
  final List<UserScript>? initialUserScripts;
  final bool showNavigationButtons;
  final String? title;

  const FramedWebView({
    Key? key,
    required this.url,
    this.zoom = 1.0,
    this.onWebViewCreated,
    this.onLoadStop,
    this.onLoadStart,
    this.onTitleChanged,
    this.initialUserScripts,
    this.showNavigationButtons = false,
    this.title,
    this.onReload,
  }) : super(key: key);

  @override
  State<FramedWebView> createState() => _FramedWebViewState();
}

class _FramedWebViewState extends State<FramedWebView> {
  late InAppWebViewController _webViewController;
  bool _isLoading = true;
  bool _showScrollButton = false;
  bool _isWebViewReady = false;
  WebViewEnvironment? _webViewEnvironment;

  @override
  void initState() {
    super.initState();
    _initializeWebViewForPlatform();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _initializeWebViewForPlatform() async {
    if (!Platform.isWindows) {
      setState(() {
        _isWebViewReady = true;
      });
      return;
    }

    try {
      // Check if WebView2 Runtime is available
      final version = await WebViewEnvironment.getAvailableVersion();
      if (version == null) {
        appLogger.w('WebView2 Runtime not available');
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('WebView2 Runtime Required'),
              content: const Text(
                'The WebView2 Runtime is required on Windows. '
                'Please install it from the Microsoft website.',
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await launchUrl(
                      Uri.parse(
                          'https://developer.microsoft.com/microsoft-edge/webview2/'),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  child: const Text('Download WebView2 Runtime'),
                ),
                TextButton(
                  onPressed: () {
                    // Close the dialog
                    Navigator.of(context).pop();
                    // Go back to the previous screen
                    Navigator.of(context).pop();
                  },
                  child: const Text('Cancel'),
                ),
              ],
            ),
          );
        }
        return;
      }

      // Set up WebView2 environment with custom user data folder
      final appDir = await getApplicationSupportDirectory();
      final webViewDataDir = path.join(appDir.path, 'WebView2Data');

      // Create the directory if it doesn't exist
      await Directory(webViewDataDir).create(recursive: true);

      // Initialize WebView2 environment with custom settings
      _webViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          additionalBrowserArguments: '--disable-web-security',
          userDataFolder: webViewDataDir,
        ),
      );

      if (mounted) {
        setState(() {
          _isWebViewReady = true;
        });
      }
    } catch (e) {
      appLogger.e('Error initializing WebView2: $e');
    }
  }

  Future<void> _checkScrollPosition() async {
    final scrollScript = '''
      (function() {
        try {
          const scrollY = Math.floor(window.scrollY);
          const documentHeight = Math.floor(document.documentElement.scrollHeight);
          const windowHeight = Math.floor(window.innerHeight);
          const maxScroll = documentHeight - windowHeight;
          
          window.flutter_inappwebview.callHandler('onScroll', {
            scrollY: scrollY.toString(),
            maxScroll: maxScroll.toString(),
            documentHeight: documentHeight.toString(),
            windowHeight: windowHeight.toString()
          });
        } catch (error) {
          console.error('Scroll check error:', error);
        }
      })();
    ''';

    await _webViewController.evaluateJavascript(source: scrollScript);
  }

  void _scrollToBottom() async {
    final scrollScript = '''
      (function() {
        try {
          const documentHeight = Math.floor(document.documentElement.scrollHeight);
          const windowHeight = Math.floor(window.innerHeight);
          const scrollTo = documentHeight - windowHeight;
          
          window.scrollTo({
            top: scrollTo,
            behavior: 'smooth'
          });
        } catch (error) {
          console.error('Scroll to bottom error:', error);
        }
      })();
    ''';

    await _webViewController.evaluateJavascript(source: scrollScript);
    _checkScrollPosition();
  }

  @override
  Widget build(BuildContext context) {
    // Show loading screen if WebView2 is not ready on Windows
    if (!_isWebViewReady) {
      return Scaffold(
        appBar: widget.showNavigationButtons
            ? AppBar(
                centerTitle: true,
                title: Center(child: Text(widget.title ?? '')),
              )
            : null,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Waiting for WebView to initialize...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: widget.showNavigationButtons
          ? AppBar(
              centerTitle: true,
              title: Center(child: Text(widget.title ?? '')),
              actions: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    _webViewController.goBack();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () {
                    _webViewController.goForward();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () {
                    if (widget.onReload != null) {
                      widget.onReload!(_webViewController);
                    } else {
                      _webViewController.reload();
                    }
                  },
                ),
              ],
            )
          : null,
      body: Center(
        child: Stack(
          children: [
            Container(
              width: MediaQuery.of(context).size.width * 0.9,
              height: (MediaQuery.of(context).size.height) * 0.9,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.grey.shade300,
                  width: 2.0,
                ),
                borderRadius: BorderRadius.circular(8),
                color: Colors.white,
              ),
              child: InAppWebView(
                webViewEnvironment: _webViewEnvironment,
                initialSettings: InAppWebViewSettings(
                  pageZoom: widget.zoom,
                  disableDefaultErrorPage: true,
                  disableContextMenu: false,
                  disableHorizontalScroll: false,
                  disableVerticalScroll: false,
                  transparentBackground: true,
                  supportZoom: true,
                  allowFileAccessFromFileURLs: true,
                  allowUniversalAccessFromFileURLs: true,
                  javaScriptEnabled: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                  mediaPlaybackRequiresUserGesture: false,
                  minimumFontSize: 1,
                  useShouldOverrideUrlLoading: true,
                  useOnLoadResource: true,
                  useOnDownloadStart: true,
                  useShouldInterceptAjaxRequest: true,
                  useShouldInterceptFetchRequest: true,
                  incognito: false,
                  cacheEnabled: true,
                  supportMultipleWindows: false,
                  allowFileAccess: true,
                  allowContentAccess: true,
                  databaseEnabled: true,
                  domStorageEnabled: true,
                  mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                ),
                initialUserScripts: widget.initialUserScripts != null
                    ? UnmodifiableListView(widget.initialUserScripts!)
                    : null,
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                  if (widget.onWebViewCreated != null) {
                    widget.onWebViewCreated!(controller);
                  }
                  controller.loadUrl(
                      urlRequest: URLRequest(url: WebUri(widget.url)));
                  controller.addJavaScriptHandler(
                    handlerName: 'onScroll',
                    callback: (args) {
                      try {
                        if (args.isNotEmpty && args[0] is Map) {
                          final data = args[0] as Map;
                          final scrollY =
                              double.tryParse(data['scrollY'] as String) ?? 0;
                          final maxScroll =
                              double.tryParse(data['maxScroll'] as String) ?? 0;

                          setState(() {
                            _showScrollButton = scrollY < maxScroll - 10;
                          });
                        }
                      } catch (e) {
                        appLogger.e('Error processing scroll data: $e');
                      }
                    },
                  );
                  appLogger.d('WebView created');
                },
                onLoadStart: (controller, url) {
                  appLogger.d('Loading started: $url');
                  setState(() {
                    _isLoading = true;
                  });
                  if (widget.onLoadStart != null) {
                    widget.onLoadStart!(controller, url);
                  }
                },
                onLoadStop: (controller, url) {
                  appLogger.d('Loading stopped: $url');
                  setState(() {
                    _isLoading = false;
                  });
                  _checkScrollPosition();
                  if (widget.onLoadStop != null) {
                    widget.onLoadStop!(controller, url);
                  }
                },
                onTitleChanged: (controller, title) {
                  appLogger.d('Title changed: $title');
                  setState(() {
                    _isLoading = false;
                  });
                  if (widget.onTitleChanged != null) {
                    widget.onTitleChanged!(controller, title);
                  }
                },
                onReceivedError: (controller, request, error) {
                  appLogger.e('Received error: ${error.description}');
                  setState(() {
                    _isLoading = false;
                  });
                  MainApp.showSnackBar('Error: ${error.description}',
                      isError: true);
                },
                onScrollChanged: (controller, x, y) {
                  _checkScrollPosition();
                },
                onReceivedServerTrustAuthRequest:
                    (controller, challenge) async {
                  appLogger.d('Received server trust auth request...');
                  return ServerTrustAuthResponse(
                      action: ServerTrustAuthResponseAction.PROCEED);
                },
                shouldOverrideUrlLoading: (controller, navigationAction) async {
                  return NavigationActionPolicy.ALLOW;
                },
              ),
            ),
            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(),
              ),
            if (_showScrollButton)
              Positioned(
                right: 16,
                bottom: 16,
                child: FloatingActionButton(
                  onPressed: _scrollToBottom,
                  child: const Icon(Icons.arrow_downward),
                  mini: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
