//! Manually Validated by zzztzzzt-SakuraAxis 2026-05-26

use sea_orm::{ConnectionTrait, DatabaseConnection, Statement, Value};
use serde_json::{json, Value as JsonValue, Map};

fn validate_identifier(name: &str) -> Result<&str, String> {
    if name.is_empty() {
        return Err("Identifier cannot be empty".to_string());
    }
    
    let has_invalid = name.as_bytes().iter().any(|&b| {
        !b.is_ascii_alphanumeric() && b != b'_'
    });

    if has_invalid {
        return Err(format!("Invalid identifier '{}'", name));
    }
    
    Ok(name)
}

pub async fn handle_native_request(
    table_name: &str,
    db: &DatabaseConnection,
    method: &str,
    path: &str,
    query: &str,
    body: &[u8],
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
                let limit = extract_query_param(query, "limit").and_then(|s| s.parse::<u64>().ok()).unwrap_or(100);
                let offset = extract_query_param(query, "offset").and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
                
                let safe_limit = std::cmp::min(limit, 10000);

                let stmt = Statement::from_string(
                    backend,
                    format!("SELECT * FROM {} LIMIT {} OFFSET {}", table_name, safe_limit, offset),
                );
                let query_res = db.query_all_raw(stmt).await.map_err(|e| e.to_string())?;

                let mut rows = Vec::with_capacity(query_res.len());
                for row in query_res {
                    rows.push(row_to_json(row)?);
                }

                Ok(serde_json::to_string(&rows).unwrap())
            }
        }

        "DELETE" => {
            let id = extract_id(path).ok_or_else(|| "Resource ID required".to_string())?;
            let stmt = Statement::from_sql_and_values(
                backend,
                format!("DELETE FROM {} WHERE id = ?", table_name),
                [Value::String(Some(id))],
            );
            db.execute_raw(stmt).await.map_err(|e| e.to_string())?;

            Ok(json!({ "status": "success", "action": "deleted" }).to_string())
        }

        "POST" => {
            let json_body: JsonValue = serde_json::from_slice(body).map_err(|e| e.to_string())?;
            let obj = json_body.as_object().ok_or("Request body must be a JSON object")?;

            if obj.is_empty() {
                return Err("Request body cannot be empty".to_string());
            }

            let len = obj.len();
            let mut keys = Vec::with_capacity(len);
            let mut values = Vec::with_capacity(len);
            let mut placeholders = Vec::with_capacity(len);

            for (k, v) in obj {
                keys.push(validate_identifier(k)?);
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
            let id = extract_id(path).ok_or_else(|| "Resource ID required".to_string())?;
            let json_body: JsonValue = serde_json::from_slice(body).map_err(|e| e.to_string())?;
            let obj = json_body.as_object().ok_or("Request body must be a JSON object")?;

            if obj.is_empty() {
                return Err("Request body cannot be empty".to_string());
            }

            let len = obj.len();
            let mut set_clauses = Vec::with_capacity(len);
            let mut values = Vec::with_capacity(len + 1);

            for (k, v) in obj {
                set_clauses.push(format!("{} = ?", validate_identifier(k)?));
                values.push(json_to_value(v.clone()));
            }

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
        .filter(|s| !s.is_empty() && s.as_bytes().iter().all(|b| b.is_ascii_digit()))
        .map(|s| s.to_string())
}

fn extract_query_param<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    query.split('&').find_map(|part| {
        let remainder = part.strip_prefix(key)?;
        remainder.strip_prefix('=')
    })
}

/// Dynamic Row -> JSON conversion
fn row_to_json(row: sea_orm::QueryResult) -> Result<JsonValue, String> {
    let mut map = Map::new();
    
    for col in row.column_names() {
        let value = column_to_json(&row, &col);
        map.insert(col, value);
    }

    Ok(JsonValue::Object(map))
}

fn column_to_json(row: &sea_orm::QueryResult, col: &str) -> JsonValue {
    if let Ok(Some(v)) = row.try_get::<Option<JsonValue>>("", col) {
        return v;
    }

    if let Ok(Some(v)) = row.try_get::<Option<i64>>("", col) {
        return json!(v);
    }

    if let Ok(Some(v)) = row.try_get::<Option<f64>>("", col) {
        return json!(v);
    }

    if let Ok(Some(v)) = row.try_get::<Option<String>>("", col) {
        return json!(v);
    }

    if let Ok(Some(v)) = row.try_get::<Option<bool>>("", col) {
        return json!(v);
    }

    if let Ok(Some(v)) = row.try_get::<Option<Vec<u8>>>("", col) {
        return json!(v);
    }

    JsonValue::Null
}

fn json_to_value(v: JsonValue) -> Value {
    match v {
        JsonValue::Null => Value::String(None),
        
        JsonValue::Bool(b) => Value::Bool(Some(b)),
        
        JsonValue::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::BigInt(Some(i))
            } else if let Some(f) = n.as_f64() {
                Value::Double(Some(f))
            } else {
                Value::String(None)
            }
        }
        
        JsonValue::String(s) => Value::String(Some(s)),
        
        JsonValue::Array(_) | JsonValue::Object(_) => Value::Json(Some(Box::new(v))),
    }
}
