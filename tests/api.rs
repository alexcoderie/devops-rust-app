use axum::body::Body;
use axum::http::{Request, StatusCode};
use router::create_router;
use std::collections::HashSet;
use tower::util::ServiceExt;

#[tokio::test]
async fn root_returns_200() {
    let app = create_router();
    let response = app
        .oneshot(Request::builder().uri("/").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn health_returns_ok() {
    let app = create_router();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(&body[..], b"ok");
}

#[tokio::test]
async fn version_is_not_empty() {
    let app = create_router();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/version")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert!(!body.is_empty());
}

#[tokio::test]
async fn unknown_route_returns_404() {
    let app = create_router();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/does-not-exist")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn echo_returns_message() {
    let app = create_router();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/echo?message=hello")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(&body[..], b"hello");
}

#[tokio::test]
async fn echo_without_message_returns_fallback() {
    let app = create_router();
    let response = app
        .oneshot(Request::builder().uri("/echo").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(&body[..], b"No message provided!");
}

#[tokio::test]
async fn products_returns_json_list() {
    let app = create_router();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/products")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let products: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let products = products.as_array().unwrap();

    assert!(products.len() >= 3);
    let mut ids = HashSet::new();
    for product in products {
        assert!(product["id"].is_u64());
        assert!(product["name"].is_string());
        assert!(product["price_cents"].is_u64());
        assert!(ids.insert(product["id"].as_u64().unwrap()));
    }
}

#[tokio::test]
async fn product_id_returns_one_product() {
    let app = create_router();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/products/2")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let product: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(product["id"], 2);
    assert_eq!(product["name"], "Mouse");
    assert_eq!(product["price_cents"], 4999);
}

#[tokio::test]
async fn unknown_product_id_returns_404() {
    let app = create_router();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/products/999")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn non_numeric_product_id_returns_400() {
    let app = create_router();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/products/not-a-number")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}
