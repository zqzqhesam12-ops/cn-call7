from fastapi import FastAPI, WebSocket, WebSocketDisconnect

app = FastAPI(title="CN CALL Server")

connections: dict[str, WebSocket] = {}


@app.get("/")
async def root():
    return {
        "app": "CN CALL",
        "status": "online",
    }


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "users": len(connections),
    }


@app.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str):
    await websocket.accept()

    old = connections.get(user_id)

    if old is not None:
        try:
            await old.close()
        except Exception:
            pass

    connections[user_id] = websocket

    try:
        await websocket.send_json({
            "type": "connected",
            "user_id": user_id,
        })

        while True:
            message = await websocket.receive_json()

            target_id = str(message.get("target_id", "")).strip()

            if target_id and target_id in connections:
                await connections[target_id].send_json({
                    **message,
                    "from_id": user_id,
                })

    except WebSocketDisconnect:
        pass

    finally:
        if connections.get(user_id) is websocket:
            del connections[user_id]
