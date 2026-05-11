use axum::{Router, routing::get};

pub fn create_router() -> Router {
    Router::new()
        .route("/", get(root))
        .route("/health", get(health))
        .route("/version", get(version))
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
