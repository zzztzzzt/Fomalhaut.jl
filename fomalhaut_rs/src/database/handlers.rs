use sea_orm::{ConnectionTrait, DatabaseConnection, Statement, Value};
use serde_json::{json, Value as JsonValue, Map};

// Identifier validation : Only alphanumeric characters and underscores are allowed
fn validate_identifier(name: &str) -> Result<&str, String> {
    if name.is_empty() {
        return Err("Identifier cannot be empty".to_string());
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(format!("Invalid identifier '{}'", name));
    }
    Ok(name)
}

pub async fn handle_native_request(
    table_name: &str,
    db: DatabaseConnection,
    method: &str,
    path: &str,
    query: &str,
    _body: Vec<u8>,
) -> Result<String, String> {
    validate_identifier(table_name)?;

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
                // Parse pagination from query string
                let limit = extract_query_param(query, "limit").and_then(|s| s.parse::<u64>().ok()).unwrap_or(100);
                let offset = extract_query_param(query, "offset").and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
                
                // Security cap : never allow more than 10000 items in one go
                let safe_limit = std::cmp::min(limit, 10000);

                let stmt = Statement::from_string(
                    backend,
                    format!("SELECT * FROM {} LIMIT {} OFFSET {}", table_name, safe_limit, offset),
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

        "POST" => {
            let json_body: JsonValue = serde_json::from_slice(&_body).map_err(|e| e.to_string())?;
            let obj = json_body.as_object().ok_or("Request body must be a JSON object")?;

            if obj.is_empty() {
                return Err("Request body cannot be empty".to_string());
            }

            let mut keys = Vec::new();
            let mut values = Vec::new();
            let mut placeholders = Vec::new();

            for (k, v) in obj {
                keys.push(validate_identifier(k)?.to_string());
                values.push(json_to_value(v.clone()));
                placeholders.push("?");
            }

            let sql = format!(
                "INSERT INTO {} ({}) VALUES ({})",
                table_name,
                keys.join(", "),
                placeholders.join(", ")
            );

            let stmt = Statement::from_sql_and_values(backend, sql, values);
            db.execute_raw(stmt).await.map_err(|e| e.to_string())?;

            Ok(json!({ "status": "success", "action": "created" }).to_string())
        }

        "PUT" | "PATCH" => {
            let id = extract_id(path).ok_or("Resource ID required")?;
            let json_body: JsonValue = serde_json::from_slice(&_body).map_err(|e| e.to_string())?;
            let obj = json_body.as_object().ok_or("Request body must be a JSON object")?;

            if obj.is_empty() {
                return Err("Request body cannot be empty".to_string());
            }

            let mut set_clauses = Vec::new();
            let mut values = Vec::new();

            for (k, v) in obj {
                set_clauses.push(format!("{} = ?", validate_identifier(k)?));
                values.push(json_to_value(v.clone()));
            }

            // ID for the WHERE clause
            values.push(Value::String(Some(id)));

            let sql = format!(
                "UPDATE {} SET {} WHERE id = ?",
                table_name,
                set_clauses.join(", ")
            );

            let stmt = Statement::from_sql_and_values(backend, sql, values);
            db.execute_raw(stmt).await.map_err(|e| e.to_string())?;

            Ok(json!({ "status": "success", "action": "updated" }).to_string())
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

fn extract_query_param<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    query.split('&')
        .find(|part| part.starts_with(key) && part.contains('='))
        .and_then(|part| part.split('=').nth(1))
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

fn json_to_value(v: JsonValue) -> Value {
    match v {
        JsonValue::Null => Value::String(None),
        JsonValue::Bool(b) => b.into(),
        JsonValue::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.into()
            } else if let Some(f) = n.as_f64() {
                f.into()
            } else {
                Value::String(None)
            }
        }
        JsonValue::String(s) => s.into(),
        JsonValue::Array(a) => serde_json::to_string(&a).unwrap_or_default().into(),
        JsonValue::Object(o) => serde_json::to_string(&o).unwrap_or_default().into(),
    }
}
