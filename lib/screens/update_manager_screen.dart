import 'package:c4_tools/main.dart' show MainApp;
import 'package:c4_tools/services/app_logger.dart' show appLogger;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../widgets/framed_webview.dart';

class UpdateManagerScreen extends StatefulWidget {
  final String directorIP;
  final String jwtToken;

  const UpdateManagerScreen({
    Key? key,
    required this.directorIP,
    required this.jwtToken,
  }) : super(key: key);

  @override
  State<UpdateManagerScreen> createState() => _UpdateManagerScreenState();
}

class _UpdateManagerScreenState extends State<UpdateManagerScreen> {
  late InAppWebViewController _webViewController;
  bool _isLoading = true;
  bool _isApiLoading = false;

  @override
  Widget build(BuildContext context) {
    // Detect if the app is in dark mode
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        FramedWebView(
          url:
              'https://${widget.directorIP}:443/api/v1/agents/update_manager/html?JWT=${widget.jwtToken}',
          showNavigationButtons: true,
          title: 'Update Manager',
          onWebViewCreated: (controller) {
            _webViewController = controller;
            appLogger.d('Update Manager WebView created');

            // Add JavaScript handler to monitor network requests
            controller.addJavaScriptHandler(
                handlerName: 'apiRequestStarted',
                callback: (args) {
                  setState(() {
                    _isApiLoading = true;
                  });
                });

            controller.addJavaScriptHandler(
                handlerName: 'apiRequestFinished',
                callback: (args) {
                  setState(() {
                    _isApiLoading = false;
                  });
                });

            // Add handler for alert messages
            controller.addJavaScriptHandler(
                handlerName: 'onAlertMessage',
                callback: (args) {
                  if (args.isNotEmpty && args[0] != null) {
                    final message = args[0].toString();
                    appLogger.d('Alert intercepted: $message');
                    // We don't care about 401 errors
                    if (!message.contains('Unauthorized')) {
                      MainApp.showSnackBar(message);
                    }
                  }
                });
          },
          onLoadStart: (controller, url) {
            appLogger.d('Update Manager loading started: $url');
            setState(() {
              _isLoading = true;
            });
          },
          onLoadStop: (controller, url) async {
            appLogger.d('Update Manager onLoadStop: $url');

            // Inject the code to monitor network requests
            final monitorRequestsScript = '''
              (function() {
                // Override fetch to monitor API requests
                const originalFetch = window.fetch;
                window.fetch = async function(url, options) {
                  if (url && typeof url === 'string' && url.includes('/api/v1/agents/update_manager/')) {
                    window.flutter_inappwebview.callHandler('apiRequestStarted');
                    try {
                      const response = await originalFetch(url, options);
                      window.flutter_inappwebview.callHandler('apiRequestFinished');
                      return response;
                    } catch (error) {
                      window.flutter_inappwebview.callHandler('apiRequestFinished');
                      throw error;
                    }
                  }
                  return originalFetch(url, options);
                };
                
                // Also override XMLHttpRequest
                const originalXHROpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                  if (url && typeof url === 'string' && url.includes('/api/v1/agents/update_manager/')) {
                    this.addEventListener('loadstart', () => {
                      window.flutter_inappwebview.callHandler('apiRequestStarted');
                    });
                    this.addEventListener('loadend', () => {
                      window.flutter_inappwebview.callHandler('apiRequestFinished');
                    });
                  }
                  return originalXHROpen.call(this, method, url, ...rest);
                };
                
                return true;
              })();
            ''';

            try {
              await _webViewController.evaluateJavascript(
                  source: monitorRequestsScript);
              appLogger.d('Update Manager request monitoring initialized');
            } catch (e) {
              appLogger.e('Error setting up request monitoring: $e');
            }

            // Inject CSS with dark mode support and modify the Update URL
            final cssAndUrlScript = '''
              (function() {
                // Override window.alert to send to Flutter
                const originalAlert = window.alert;
                window.alert = function(message) {
                  // Send alert message to Flutter
                  window.flutter_inappwebview.callHandler('onAlertMessage', message);
                  console.log('Alert intercepted: ' + message);
                };
                
                // Create and inject custom styles with dark mode support
                const style = document.createElement('style');
                style.textContent = `
                  body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif !important;
                    color: ${isDarkMode ? '#e0e0e0' : '#333'} !important;
                    background-color: ${isDarkMode ? '#121212' : '#f8f9fa'} !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    transition: background-color 0.3s ease, color 0.3s ease !important;
                  }
                  
                  .container, .container-fluid {
                    max-width: 1200px !important;
                    margin: 0 auto !important;
                    padding: 20px !important;
                  }
                  
                  h1, h2, h3, h4, h5, h6 {
                    color: ${isDarkMode ? '#e0e0e0' : '#2c3e50'} !important;
                    margin-bottom: 1rem !important;
                  }
                  
                  button, .btn {
                    background-color: ${isDarkMode ? '#0d6efd' : '#3498db'} !important;
                    border-color: ${isDarkMode ? '#0d6efd' : '#3498db'} !important;
                    color: white !important;
                    padding: 8px 16px !important;
                    border-radius: 4px !important;
                    font-weight: 500 !important;
                    transition: all 0.2s ease !important;
                  }
                  
                  button:hover, .btn:hover {
                    background-color: ${isDarkMode ? '#0b5ed7' : '#2980b9'} !important;
                    border-color: ${isDarkMode ? '#0b5ed7' : '#2980b9'} !important;
                  }
                  
                  table {
                    width: 100% !important;
                    border-collapse: collapse !important;
                    margin-bottom: 1rem !important;
                    background-color: ${isDarkMode ? '#1e1e1e' : 'white'} !important;
                    box-shadow: 0 1px 3px ${isDarkMode ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.1)'} !important;
                  }
                  
                  th {
                    background-color: ${isDarkMode ? '#2d2d2d' : '#f1f1f1'} !important;
                    padding: 12px 15px !important;
                    text-align: left !important;
                    font-weight: 600 !important;
                    border-bottom: 2px solid ${isDarkMode ? '#444' : '#ddd'} !important;
                  }
                  
                  td {
                    padding: 10px 15px !important;
                    border-bottom: 1px solid ${isDarkMode ? '#444' : '#eee'} !important;
                  }
                  
                  tr:hover {
                    background-color: ${isDarkMode ? '#2a2a2a' : '#f5f8fa'} !important;
                  }
                  
                  input, select {
                    border: 1px solid ${isDarkMode ? '#444' : '#ddd'} !important;
                    border-radius: 4px !important;
                    padding: 8px 12px !important;
                    width: 100% !important;
                    margin-bottom: 1rem !important;
                    background-color: ${isDarkMode ? '#2d2d2d' : 'white'} !important;
                    color: ${isDarkMode ? '#e0e0e0' : '#333'} !important;
                  }
                  
                  .progress {
                    height: 20px !important;
                    border-radius: 4px !important;
                    background-color: ${isDarkMode ? '#2d2d2d' : '#ecf0f1'} !important;
                    margin-bottom: 1rem !important;
                  }
                  
                  .progress-bar {
                    background-color: ${isDarkMode ? '#0d6efd' : '#3498db'} !important;
                    height: 100% !important;
                  }
                  
                  .alert {
                    padding: 12px 15px !important;
                    border-radius: 4px !important;
                    margin-bottom: 1rem !important;
                  }
                  
                  .alert-success {
                    background-color: ${isDarkMode ? '#0d4a16' : '#d4edda'} !important;
                    color: ${isDarkMode ? '#9be69b' : '#155724'} !important;
                    border-color: ${isDarkMode ? '#095c12' : '#c3e6cb'} !important;
                  }
                  
                  .alert-danger {
                    background-color: ${isDarkMode ? '#4a0d0d' : '#f8d7da'} !important;
                    color: ${isDarkMode ? '#e69b9b' : '#721c24'} !important;
                    border-color: ${isDarkMode ? '#5c0909' : '#f5c6cb'} !important;
                  }
                  
                  .alert-warning {
                    background-color: ${isDarkMode ? '#4a400d' : '#fff3cd'} !important;
                    color: ${isDarkMode ? '#e6d89b' : '#856404'} !important;
                    border-color: ${isDarkMode ? '#5c4f09' : '#ffeeba'} !important;
                  }
                  
                  /* Specific fixes for Update Manager UI */
                  #update-manager-app {
                    padding: 20px !important;
                    background-color: ${isDarkMode ? '#121212' : '#f8f9fa'} !important;
                  }
                  
                  .card {
                    border-radius: 6px !important;
                    box-shadow: 0 2px 5px ${isDarkMode ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.1)'} !important;
                    margin-bottom: 20px !important;
                    background-color: ${isDarkMode ? '#1e1e1e' : 'white'} !important;
                    border: 1px solid ${isDarkMode ? '#2d2d2d' : '#eee'} !important;
                  }
                  
                  .card-header {
                    background-color: ${isDarkMode ? '#2d2d2d' : '#f8f9fa'} !important;
                    border-bottom: 1px solid ${isDarkMode ? '#444' : '#eee'} !important;
                    padding: 15px 20px !important;
                    color: ${isDarkMode ? '#e0e0e0' : '#333'} !important;
                  }
                  
                  .card-body {
                    padding: 20px !important;
                    color: ${isDarkMode ? '#e0e0e0' : '#333'} !important;
                  }
                  
                  /* Force text colors for all text elements */
                  p, span, div, label, strong, em, small, a, li {
                    color: ${isDarkMode ? '#e0e0e0' : '#333'} !important;
                  }
                  
                  a {
                    color: ${isDarkMode ? '#63a4ff' : '#0066cc'} !important;
                  }
                  
                  a:hover {
                    color: ${isDarkMode ? '#82b7ff' : '#0055aa'} !important;
                  }
                  
                  /* Override any modal/dialog backgrounds */
                  .modal, .modal-content, .popover, .tooltip, .dropdown-menu {
                    background-color: ${isDarkMode ? '#1e1e1e' : 'white'} !important;
                    color: ${isDarkMode ? '#e0e0e0' : '#333'} !important;
                    border-color: ${isDarkMode ? '#444' : '#ddd'} !important;
                  }
                  
                  /* Fix code blocks or pre elements */
                  pre, code {
                    background-color: ${isDarkMode ? '#2d2d2d' : '#f5f5f5'} !important;
                    color: ${isDarkMode ? '#e0e0e0' : '#333'} !important;
                    border: 1px solid ${isDarkMode ? '#444' : '#ddd'} !important;
                    border-radius: 4px !important;
                  }
                  
                  /* Force scrollbar styling */
                  ::-webkit-scrollbar {
                    width: 10px !important;
                    height: 10px !important;
                  }
                  
                  ::-webkit-scrollbar-track {
                    background: ${isDarkMode ? '#2d2d2d' : '#f1f1f1'} !important;
                  }
                  
                  ::-webkit-scrollbar-thumb {
                    background: ${isDarkMode ? '#555' : '#888'} !important;
                    border-radius: 5px !important;
                  }
                  
                  ::-webkit-scrollbar-thumb:hover {
                    background: ${isDarkMode ? '#777' : '#555'} !important;
                  }
                `;
                document.head.appendChild(style);
                
                // Add viewport meta tag for proper scaling
                const meta = document.createElement('meta');
                meta.name = 'viewport';
                meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                document.head.appendChild(meta);
                
                // Add event listeners for log monitoring
                const logContainer = document.querySelector('.log-container');
                if (logContainer) {
                  const observer = new MutationObserver((mutations) => {
                    // If new log entries are added, scroll to bottom
                    logContainer.scrollTop = logContainer.scrollHeight;
                  });
                  
                  observer.observe(logContainer, {
                    childList: true,
                    subtree: true
                  });
                }
                
                // Function to change the default update URL
                function changeDefaultUpdateUrl() {
                  // Look for the update URL input field
                  const urlInputs = Array.from(document.querySelectorAll('input[type="text"]'));
                  const updateUrlInput = urlInputs.find(input => {
                    return input.value && input.value.includes('Updates2x-engineering/v2_0/Updates.asmx');
                  });
                  
                  if (updateUrlInput) {
                    console.log('Found update URL input, changing default');
                    updateUrlInput.value = 'http://services.control4.com/Updates2x-experience/v2_0/Updates.asmx';
                    
                    // Trigger change event
                    const event = new Event('change', { bubbles: true });
                    updateUrlInput.dispatchEvent(event);
                    
                    // Also trigger input event
                    const inputEvent = new Event('input', { bubbles: true });
                    updateUrlInput.dispatchEvent(inputEvent);
                    
                    return true;
                  }
                  
                  return false;
                }
                
                // Try to change URL immediately, then retry if necessary
                if (!changeDefaultUpdateUrl()) {
                  // If not successful, try again after a short delay
                  setTimeout(() => {
                    changeDefaultUpdateUrl();
                  }, 1000);
                  
                  // Set up a MutationObserver to detect when the input might be available
                  const bodyObserver = new MutationObserver((mutations) => {
                    if (changeDefaultUpdateUrl()) {
                      bodyObserver.disconnect();
                    }
                  });
                  
                  bodyObserver.observe(document.body, {
                    childList: true,
                    subtree: true
                  });
                }
                
                console.log('Update Manager UI enhancements applied for ${isDarkMode ? 'dark' : 'light'} mode');
                return true;
              })();
            ''';

            try {
              await _webViewController.evaluateJavascript(
                  source: cssAndUrlScript);
              appLogger.d(
                  'Update Manager CSS and URL modification completed for ${isDarkMode ? 'dark' : 'light'} mode');
            } catch (e) {
              appLogger.e('Error injecting CSS or modifying URL: $e');
              MainApp.showSnackBar('Error customizing UI: $e', isError: true);
            }

            setState(() {
              _isLoading = false;
            });
          },
          onReload: (controller) {
            controller.loadUrl(
                urlRequest: URLRequest(
                    url: WebUri(
                        'https://${widget.directorIP}:443/api/v1/agents/update_manager/html?JWT=${widget.jwtToken}')));
          },
        ),
        if (_isApiLoading)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.3),
              child: Center(
                child: Card(
                  elevation: 4,
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Stack(alignment: Alignment.center, children: [
                          CircularProgressIndicator(),
                          IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'Stop Loading',
                            onPressed: () {
                              setState(() {
                                _isApiLoading = false;
                              });
                            },
                          ),
                        ]),
                        SizedBox(height: 16),
                        Text(
                          'Loading Update Data...',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
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
