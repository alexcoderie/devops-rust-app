use std::collections::HashMap;

use axum::{Router, extract::Query, routing::get};

pub fn create_router() -> Router {
    Router::new()
        .route("/", get(root))
        .route("/health", get(health))
        .route("/version", get(version))
        .route("/echo", get(echo))
}

async fn root() -> &'static str {
    "Hello from fly.io!"
}

async fn health() -> &'static str {
    "ok"
}

async fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

async fn echo(Query(params): Query<HashMap<String, String>>) -> String {
    match params.get("message") {
        Some(msg) => msg.clone(),
        None => "No message provided!".to_string(),
    }
}
