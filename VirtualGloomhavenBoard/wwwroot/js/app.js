"use strict";
(() => {
    document.body.addEventListener("dragstart", event => {
        if (event.target && event.target.draggable) {
            // Absurdly, this is needed for Firefox; see https://medium.com/elm-shorts/elm-drag-and-drop-game-630205556d2
            event.dataTransfer.setData("text/html", "blank");
            let emptyImage = document.createElement('img');
            // Set the src to be a 0x0 gif
            emptyImage.src = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';
            event.dataTransfer.setDragImage(emptyImage, 0, 0);
        }
    });

    document.body.addEventListener("dragover", event => {
        // This is needed in order to make dragging work
        return false;
    });

    const app = Elm.Main.init({
        node: document.getElementById("elm-node"),
        flags: [
            JSON.parse(window.localStorage.getItem("state"))
            , Math.floor(Math.random() * Math.floor(4000))
        ]
    });

    const conn = new signalR
        .HubConnectionBuilder()
        .withUrl("/ws")
        .configureLogging(signalR.LogLevel.Information)
        .withAutomaticReconnect([0, 3000, 5000, 10000, 15000, 30000])
        .build()
    ;

    let lastGameState = null;
    let roomCode = null;

    conn.onreconnected(() => app.ports.connected.send(null));
    conn.onreconnecting(() => app.ports.reconnecting.send(null));
    conn.onclose(() => app.ports.disconnected.send(null));

    conn.on("RoomCreated", (newRoomCode) => {
        roomCode = newRoomCode;
        app.ports.receiveRoomCode.send(newRoomCode)
    });

    conn.on("InvalidRoomCode", (roomCode) =>
        app.ports.invalidRoomCode.send(null)
    );

    conn.on("ReceiveGameState", (state) => {
        app.ports.receiveUpdate.send(state)
    });

    conn.on("PushGameState", () => {
        if (lastGameState !== null && roomCode !== null)
            conn
                .invoke("SendGameState", roomCode, lastGameState)
                .catch(err => console.error(err))
            ;
    });

    app.ports.saveData.subscribe((data) =>
        window.localStorage.setItem("state", JSON.stringify(data))
    );

    app.ports.connect.subscribe (async (seed) => {
        if (conn.state === signalR.HubConnectionState.Disconnected) {
            try {
                await conn.start(seed);
                app.ports.connected.send(null);
            } catch (err) {
                console.log(err);
                app.ports.disconnected.send(null);
            }
        }
    });

    app.ports.createRoom.subscribe (() => {
        if (conn.state === signalR.HubConnectionState.Connected)
            conn
                .invoke("CreateRoom")
                .catch(err => console.error(err))
            ;
    });

    app.ports.joinRoom.subscribe ((args) => {
        const oldCode = args[0];
        const newCode = args[1];

        if (oldCode !== null)
            conn.invoke("LeaveRoom", oldCode).catch(err => console.error(err));

        roomCode = newCode;
        conn.invoke("JoinRoom", newCode).catch(err => console.error(err));
    });

    app.ports.sendUpdate.subscribe ((args) => {
        lastGameState = args[1];
        conn.invoke("SendGameState", args[0], args[1]).catch(err => console.error(err));
    });
})();