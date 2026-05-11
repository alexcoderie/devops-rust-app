use axum::{routing::get, Router};

pub fn create_router() -> Router {
    Router::new().route("/", get(root)).route("/health", get(health)).route("/version", get(version))
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

#[tokio::main]
async fn main() {
    let app = create_router();
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
