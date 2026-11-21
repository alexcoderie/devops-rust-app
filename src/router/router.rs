use std::collections::HashMap;

use axum::{Router, body::Body, extract::Query, http::Request, routing::get};
use tower_http::trace::{DefaultOnResponse, TraceLayer};
use tracing::Level;

pub fn create_router() -> Router {
    use super::products;

    Router::new()
        .route("/", get(root))
        .route("/health", get(health))
        .route("/version", get(version))
        .route("/echo", get(echo))
        .route("/products", get(products::list))
        .route("/products/{id}", get(products::get))
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(|request: &Request<Body>| {
                    tracing::info_span!(
                        "request",
                        method = %request.method(),
                        path = %request.uri().path(),
                    )
                })
                .on_response(DefaultOnResponse::new().level(Level::INFO)),
        )
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
