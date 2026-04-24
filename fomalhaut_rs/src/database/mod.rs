pub mod handlers;
use sea_orm::{Database, DatabaseConnection, DbErr};

pub async fn connect(url: &str) -> Result<DatabaseConnection, DbErr> {
    Database::connect(url).await
}
