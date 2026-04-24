use sea_orm::{ConnectionTrait, DatabaseConnection, Statement, Value};
use serde_json::{json, Value as JsonValue, Map};

pub async fn handle_native_request(
    table_name: &str,
    db: DatabaseConnection,
    method: &str,
    path: &str,
    _body: Vec<u8>,
) -> Result<String, String> {
    let backend = db.get_database_backend();

    match method {
        "GET" => {
            let id = extract_id(path);

            if let Some(id_val) = id {
                let stmt = Statement::from_sql_and_values(
                    backend,
                    format!("SELECT * FROM {} WHERE id = ?", table_name),
                    [Value::String(Some(id_val))],
                );
                
                let query_res = db.query_one_raw(stmt).await.map_err(|e| e.to_string())?;

                if let Some(row) = query_res {
                    let json_row = row_to_json(row)?;
                    Ok(serde_json::to_string(&json_row).unwrap())
                } else {
                    Err("Resource Not Found".to_string())
                }
            } else {
                let stmt = Statement::from_string(
                    backend,
                    format!("SELECT * FROM {} LIMIT 100", table_name),
                );
                let query_res = db.query_all_raw(stmt).await.map_err(|e| e.to_string())?;

                let mut rows = Vec::new();
                for row in query_res {
                    rows.push(row_to_json(row)?);
                }

                Ok(serde_json::to_string(&rows).unwrap())
            }
        }

        "DELETE" => {
            let id = extract_id(path).ok_or("Resource ID required")?;
            let stmt = Statement::from_sql_and_values(
                backend,
                format!("DELETE FROM {} WHERE id = ?", table_name),
                [Value::String(Some(id))],
            );
            db.execute_raw(stmt).await.map_err(|e| e.to_string())?;

            Ok(json!({ "status": "success", "action": "deleted" }).to_string())
        }

        _ => Err(format!("HTTP method {} not implemented for native engine", method)),
    }
}

fn extract_id(path: &str) -> Option<String> {
    path.split('/')
        .last()
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_numeric()))
        .map(|s| s.to_string())
}

/// Dynamic Row -> JSON conversion
fn row_to_json(row: sea_orm::QueryResult) -> Result<JsonValue, String> {
    let mut map = Map::new();
    
    // In SeaORM 2.x / SQLx, QueryResult provides column names.
    // We iterate through all available columns and try to extract values as strings/numbers
    for col in row.column_names() {
        // Try to get as various types and convert to JsonValue
        if let Ok(v) = row.try_get::<String>("", &col) {
            map.insert(col, json!(v));
        } else if let Ok(v) = row.try_get::<i64>("", &col) {
            map.insert(col, json!(v));
        } else if let Ok(v) = row.try_get::<f64>("", &col) {
            map.insert(col, json!(v));
        } else if let Ok(v) = row.try_get::<bool>("", &col) {
            map.insert(col, json!(v));
        } else {
            // Fallback for null or unknown types
            map.insert(col, JsonValue::Null);
        }
    }

    Ok(JsonValue::Object(map))
}
