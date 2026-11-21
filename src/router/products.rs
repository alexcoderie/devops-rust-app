use axum::{
    Json,
    extract::Path,
    http::StatusCode,
};
use serde::Serialize;

#[derive(Clone, Serialize)]
pub struct Product {
    id: u64,
    name: &'static str,
    price_cents: u64,
}

const PRODUCTS: [Product; 3] = [
    Product {
        id: 1,
        name: "Keyboard",
        price_cents: 7999,
    },
    Product {
        id: 2,
        name: "Mouse",
        price_cents: 4999,
    },
    Product {
        id: 3,
        name: "Monitor",
        price_cents: 29999,
    },
];

pub async fn list() -> Json<&'static [Product]> {
    Json(&PRODUCTS)
}

pub async fn get(Path(id): Path<u64>) -> Result<Json<Product>, StatusCode> {
    PRODUCTS
        .iter()
        .find(|product| product.id == id)
        .cloned()
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}
