use std::collections::HashMap;
use std::io;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::ffi::callbacks::invoke_http_callback;
use crate::runtime::state::{HttpRoute, state};
use crate::transport::websocket;

const HEADER_READ_LIMIT: usize = 64 * 1024;
const BODY_READ_LIMIT: usize = 32 * 1024 * 1024;
const REQUEST_TIMEOUT_SECS: u64 = 30;

pub async fn run_until_shutdown(addr: &str, shutdown_rx: tokio::sync::oneshot::Receiver<()>) {
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind HTTP server");
    println!("Fomalhaut Server: http://{}", addr);

    run_with_listener(listener, shutdown_rx).await;
}

pub async fn run_with_listener(listener: tokio::net::TcpListener, mut shutdown_rx: tokio::sync::oneshot::Receiver<()>) {
    loop {
        tokio::select! {
            _ = &mut shutdown_rx => {
                println!("Fomalhaut server shutdown signal received.");
                break;
            }
            incoming = listener.accept() => {
                match incoming {
                    Ok((stream, _)) => {
                        tokio::spawn(async move {
                            let _ = handle_connection(stream).await;
                        });
                    }
                    Err(err) => {
                        eprintln!("Accept failed: {}", err);
                    }
                }
            }
        }
    }
}

async fn handle_connection(stream: TcpStream) -> io::Result<()> {
    match tokio::time::timeout(
        std::time::Duration::from_secs(REQUEST_TIMEOUT_SECS),
        handle_connection_inner(stream)
    ).await {
        Ok(result) => result,
        Err(_) => Ok(()),
    }
}

async fn handle_connection_inner(mut stream: TcpStream) -> io::Result<()> {
    let request_head = match peek_request_head(&stream).await {
        Ok(Some(head)) => head,
        Ok(None) => {
            write_response(&mut stream, 400, "text/plain", b"Bad Request", None, None, None).await?;
            return Ok(());
        }
        Err(e) => {
            return Err(e);
        }
    };

    if is_websocket_upgrade(&request_head.headers) && websocket::route_exists(&request_head.path) {
        websocket::handle_socket(request_head.path, stream).await;
        return Ok(());
    }

    let request = match read_http_request(stream).await {
        Ok(r) => r,
        Err(e) => {
            let (status, _msg) = match e.kind() {
                io::ErrorKind::InvalidData => (400, &b"Bad Request"[..]),
                io::ErrorKind::TimedOut => (408, &b"Request Timeout"[..]),
                _ => (500, &b"Internal Server Error"[..]),
            };

            eprintln!("Request read error ({}): {}", status, e);
            return Ok(());
        }
    };

    handle_http_request(request).await
}

async fn handle_http_request(request: ParsedRequest) -> io::Result<()> {
    let origin = request.headers.get("origin").map(|s| s.as_str());
    let allow_headers = request
        .headers
        .get("access-control-request-headers")
        .map(|s| s.as_str());

    let mut stream = request.stream;

    let method_bytes = request.method.as_bytes().to_vec();
    let path_bytes = request.path.as_bytes().to_vec();
    let query_bytes = request.query.as_bytes().to_vec();
    let header_bytes = serialize_headers(&request.headers);
    let allow_methods = allowed_methods_for_path(&request.path)?;

    if request.method == "OPTIONS" {
        let options_route = {
            let guard = state()
                .lock()
                .map_err(|_| io::Error::other("Runtime lock failed"))?;
            guard
                .http_routes
                .get(&(request.method.clone(), request.path.clone()))
                .copied()
        };

        if let Some(route) = options_route {
            let body = request.body;
            let callback_result = tokio::task::spawn_blocking(move || {
                invoke_http_callback(route, &method_bytes, &path_bytes, &query_bytes, &header_bytes, &body)
            })
            .await
            .map_err(|_| io::Error::other("Callback task failed"))?;

            return match callback_result {
                Ok(response) => {
                    write_response(
                        &mut stream,
                        response.status_code,
                        &response.content_type,
                        &response.body,
                        origin,
                        allow_methods.as_deref(),
                        allow_headers,
                    )
                    .await
                }
                Err(_) => {
                    write_response(
                        &mut stream,
                        500,
                        "application/json",
                        br#"{"error":"Handler failed"}"#,
                        origin,
                        allow_methods.as_deref(),
                        allow_headers,
                    )
                    .await
                }
            };
        }

        if allow_methods.is_none() {
            return write_response(
                &mut stream,
                404,
                "application/json",
                br#"{"error":"Not Found"}"#,
                origin,
                None,
                allow_headers,
            )
            .await;
        }

        return write_response(
            &mut stream,
            204,
            "text/plain",
            b"",
            origin,
            allow_methods.as_deref(),
            allow_headers,
        )
        .await;
    }

    // Basic GET support for health checks/connectivity
    if request.method == "GET" && request.path == "/" {
        return write_response(
            &mut stream,
            200,
            "application/json",
            br#"{"status":"running","engine":"Fomalhaut"}"#,
            origin,
            Some("GET, OPTIONS"),
            allow_headers,
        ).await;
    }

    let (resolution, _matched_path) = {
        let guard = state()
            .lock()
            .map_err(|_| io::Error::other("Runtime lock failed"))?;

        let method = request.method.to_ascii_uppercase();
        let mut path = request.path.clone();
        
        // Normalize path : remove trailing slash unless it's just "/"
        if path.len() > 1 && path.ends_with('/') {
            path.pop();
        }

        let route_key = (method.clone(), path.clone());

        // 1. Try Exact Match
        if let Some(route) = guard.http_routes.get(&route_key) {
            (RouteResolution::Handler(*route), path)
        } else if let Some(entity) = guard.native_routes.get(&route_key) {
            (RouteResolution::Native(entity.clone()), path)
        } else {
            // 2. Try Parameter Match ( e.g., /api/users/:id )
            let mut found = None;
            
            // Check Native Routes
            for ((m, p), entity) in &guard.native_routes {
                if m == &method && match_dynamic_path(p, &path) {
                    found = Some((RouteResolution::Native(entity.clone()), p.clone()));
                    break;
                }
            }

            if found.is_none() {
                // Check Julia Routes
                for ((m, p), route) in &guard.http_routes {
                    if m == &method && match_dynamic_path(p, &path) {
                        found = Some((RouteResolution::Handler(*route), p.clone()));
                        break;
                    }
                }
            }

            if let Some(res) = found {
                res
            } else {
                // 3. Method Not Allowed or Not Found
                let exists_on_other_method = guard.http_routes.keys()
                    .chain(guard.native_routes.keys())
                    .any(|(_, p)| p == &path || match_dynamic_path(p, &path));

                if exists_on_other_method {
                    (RouteResolution::Immediate(405, r#"{"error":"Method Not Allowed"}"#.to_string(), "application/json"), path)
                } else {
                    (RouteResolution::Immediate(404, r#"{"error":"Not Found"}"#.to_string(), "application/json"), path)
                }
            }
        }
    };

    match resolution {
        RouteResolution::Immediate(status, message, content_type) => {
            let allow_methods = if status == 405 {
                allow_methods.as_deref()
            } else {
                None
            };
            write_response(
                &mut stream,
                status,
                content_type,
                message.as_bytes(),
                origin,
                allow_methods,
                allow_headers,
            )
            .await?;
            Ok(())
        }
        RouteResolution::Native(entity) => {
            let db = {
                let guard = state()
                    .lock()
                    .map_err(|_| io::Error::other("Runtime lock failed"))?;
                guard.db.clone()
            };

            match db {
                Some(conn) => {
                    let method = request.method.clone();
                    let path = request.path.clone();
                    let query = request.query.clone();
                    let body = request.body.clone();
                    
                    match crate::database::handlers::handle_native_request(&entity, &conn, &method, &path, &query, &body).await {
                        Ok(json_res) => {
                            write_response(
                                &mut stream,
                                200,
                                "application/json",
                                json_res.as_bytes(),
                                origin,
                                allow_methods.as_deref(),
                                allow_headers,
                            )
                            .await?;
                        }
                        Err(err) => {
                            let err_msg = format!(r#"{{"error":"Native handler failed","details":"{}"}}"#, err);
                            write_response(
                                &mut stream,
                                500,
                                "application/json",
                                err_msg.as_bytes(),
                                origin,
                                allow_methods.as_deref(),
                                allow_headers,
                            )
                            .await?;
                        }
                    }
                }
                None => {
                    write_response(
                        &mut stream,
                        503,
                        "application/json",
                        br#"{"error":"Database not connected","info":"Call connect_db() in Julia before starting server"}"#,
                        origin,
                        allow_methods.as_deref(),
                        allow_headers,
                    )
                    .await?;
                }
            }
            Ok(())
        }
        RouteResolution::Handler(route) => {
            let body = request.body;
            let callback_result = tokio::task::spawn_blocking(move || {
                invoke_http_callback(route, &method_bytes, &path_bytes, &query_bytes, &header_bytes, &body)
            })
            .await
            .map_err(|_| io::Error::other("Callback task failed"))?;

            match callback_result {
                Ok(response) => {
                    write_response(
                        &mut stream,
                        response.status_code,
                        &response.content_type,
                        &response.body,
                        origin,
                        allow_methods.as_deref(),
                        allow_headers,
                    )
                    .await?;
                }
                Err(_) => {
                    write_response(
                        &mut stream,
                        500,
                        "application/json",
                        br#"{"error":"Handler failed"}"#,
                        origin,
                        allow_methods.as_deref(),
                        allow_headers,
                    )
                    .await?;
                }
            }

            Ok(())
        }
    }
}

async fn peek_request_head(stream: &TcpStream) -> io::Result<Option<RequestHead>> {
    let mut buf = vec![0_u8; HEADER_READ_LIMIT];
    let len = stream.peek(&mut buf).await?;
    if len == 0 {
        return Ok(None);
    }
    Ok(parse_request_head(&buf[..len]))
}

async fn read_http_request(stream: TcpStream) -> io::Result<ParsedRequest> {
    tokio::time::timeout(
        std::time::Duration::from_secs(REQUEST_TIMEOUT_SECS),
        read_http_request_inner(stream)
    )
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "Request read timeout"))?
}

async fn read_http_request_inner(mut stream: TcpStream) -> io::Result<ParsedRequest> {
    let mut buffer = Vec::new();
    while find_headers_end(&buffer).is_none() {
        if buffer.len() >= HEADER_READ_LIMIT {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Request headers too large"));
        }

        let mut chunk = [0_u8; 2048];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "Request ended before headers completed"));
        }
        buffer.extend_from_slice(&chunk[..read]);
    }

    let headers_end = find_headers_end(&buffer).unwrap();
    let head = parse_request_head(&buffer[..headers_end])
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Invalid request head"))?;
    
    if let Some(te) = head.headers.get("transfer-encoding") {
        if te.to_ascii_lowercase().contains("chunked") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "chunked transfer-encoding not supported",
            ));
        }
    }

    let content_length = head
        .headers
        .get("content-length")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);

    if content_length > BODY_READ_LIMIT {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Request body too large"));
    }

    let expected_len = headers_end + content_length;
    while buffer.len() < expected_len {
        let mut chunk = [0_u8; 4096];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "Request ended before body completed"));
        }
        buffer.extend_from_slice(&chunk[..read]);
    }

    let body = buffer[headers_end..expected_len].to_vec();
    Ok(ParsedRequest {
        stream,
        method: head.method,
        path: head.path,
        query: head.query,
        headers: head.headers,
        body,
    })
}

fn percent_decode(s: &str) -> String {
    let mut result = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                result.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        result.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(result).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn parse_request_head(preview: &[u8]) -> Option<RequestHead> {
    let headers_end = find_headers_end(preview)?;
    let header_bytes = &preview[..headers_end];
    let header_text = std::str::from_utf8(header_bytes).ok()?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next()?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next()?.to_string();
    let target = request_parts.next()?.to_string();
    let _version = request_parts.next()?;

    let (path, query) = split_target(&target);
    let path = percent_decode(&path);
    let mut headers = HashMap::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }

        let mut parts = line.splitn(2, ':');
        let name = parts.next()?.trim().to_ascii_lowercase();
        let value = parts.next()?.trim().to_string();
        headers.insert(name, value);
    }

    Some(RequestHead {
        method,
        path,
        query,
        headers,
    })
}

fn split_target(target: &str) -> (String, String) {
    match target.split_once('?') {
        Some((path, query)) => (path.to_string(), query.to_string()),
        None => (target.to_string(), String::new()),
    }
}

fn find_headers_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|idx| idx + 4)
}

fn is_websocket_upgrade(headers: &HashMap<String, String>) -> bool {
    let Some(upgrade) = headers.get("upgrade") else {
        return false;
    };
    let Some(connection) = headers.get("connection") else {
        return false;
    };

    upgrade.eq_ignore_ascii_case("websocket")
        && connection
            .split(',')
            .any(|part| part.trim().eq_ignore_ascii_case("upgrade"))
}

fn serialize_headers(headers: &HashMap<String, String>) -> Vec<u8> {
    let mut serialized = Vec::new();
    for (name, value) in headers {
        serialized.extend_from_slice(name.as_bytes());
        serialized.extend_from_slice(b": ");
        serialized.extend_from_slice(value.as_bytes());
        serialized.extend_from_slice(b"\r\n");
    }
    serialized
}

async fn write_response(
    stream: &mut TcpStream,
    status_code: u16,
    content_type: &str,
    body: &[u8],
    _origin: Option<&str>,
    allow_methods: Option<&str>,
    allow_headers: Option<&str>,
) -> io::Result<()> {
    let status_text = reason_phrase(status_code);
    
    let mut header = format!(
        "HTTP/1.1 {} {}\r\n\
         Server: Fomalhaut/0.2 (Rust/Julia)\r\n\
         Content-Type: {}\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n",
        status_code,
        status_text,
        content_type,
        body.len(),
    );

    header.push_str("Access-Control-Allow-Origin: *\r\n");
    header.push_str(&format!(
        "Access-Control-Allow-Methods: {}\r\n",
        allow_methods.unwrap_or("GET, OPTIONS")
    ));
    header.push_str(&format!(
        "Access-Control-Allow-Headers: {}\r\n",
        allow_headers.unwrap_or("Content-Type, Authorization, X-Custom-Header, X-Requested-With")
    ));
    header.push_str("Vary: Origin\r\n");

    header.push_str("\r\n");

    stream.write_all(header.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.flush().await
}

fn match_dynamic_path(pattern: &str, actual: &str) -> bool {
    let p_parts: Vec<&str> = pattern.split('/').filter(|s| !s.is_empty()).collect();
    let a_parts: Vec<&str> = actual.split('/').filter(|s| !s.is_empty()).collect();

    if p_parts.len() != a_parts.len() {
        return false;
    }

    for (p, a) in p_parts.iter().zip(a_parts.iter()) {
        if p.starts_with(':') {
            continue;
        }
        if p != a {
            return false;
        }
    }
    true
}

fn allowed_methods_for_path(path: &str) -> io::Result<Option<String>> {
    let guard = state()
        .lock()
        .map_err(|_| io::Error::other("Runtime lock failed"))?;

    let normalized = if path.len() > 1 && path.ends_with('/') {
        path.trim_end_matches('/').to_string()
    } else {
        path.to_string()
    };

    let mut methods: Vec<String> = guard
        .http_routes
        .keys()
        .chain(guard.native_routes.keys())
        .filter(|(_, route_path)| {
            route_path == &normalized || match_dynamic_path(route_path, &normalized)
        })
        .map(|(method, _)| method.clone())
        .collect();

    if path == "/" && !methods.iter().any(|method| method == "GET") {
        methods.push("GET".to_string());
    }

    if methods.is_empty() {
        return Ok(None);
    }

    if !methods.iter().any(|method| method == "OPTIONS") {
        methods.push("OPTIONS".to_string());
    }

    methods.sort();
    methods.dedup();

    Ok(Some(methods.join(", ")))
}

fn reason_phrase(status_code: u16) -> &'static str {
    match status_code {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        _ => "OK",
    }
}

enum RouteResolution {
    Handler(HttpRoute),
    Native(String),
    Immediate(u16, String, &'static str),
}

struct RequestHead {
    method: String,
    path: String,
    query: String,
    headers: HashMap<String, String>,
}

struct ParsedRequest {
    stream: TcpStream,
    method: String,
    path: String,
    query: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}
