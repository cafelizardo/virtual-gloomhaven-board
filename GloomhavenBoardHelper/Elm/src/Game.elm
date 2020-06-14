module Game exposing (AIType(..), Cell, Game, GameState, NumPlayers(..), Piece, PieceType(..), assignIdentifier, assignPlayers, generateGameMap, getPieceName, getPieceType, moveOverlay, movePiece, removePieceFromBoard, revealRooms)

import Array exposing (Array, fromList, get, indexedMap, initialize, length, push, set, slice, toList)
import Bitwise exposing (and)
import BoardMapTile exposing (MapTile, MapTileRef, refToString)
import BoardOverlay exposing (BoardOverlay, BoardOverlayDirectionType(..), BoardOverlayType(..), DoorSubType(..), TreasureSubType(..), getBoardOverlayName)
import Character exposing (CharacterClass, characterToString)
import Dict exposing (Dict, get, insert)
import Hexagon exposing (cubeToOddRow, oddRowToCube)
import List exposing (any, filter, filterMap, foldl, head, map, member)
import List.Extra exposing (uniqueBy)
import Monster exposing (Monster, MonsterLevel(..), getMonsterBucketSize, monsterTypeToString)
import Random exposing (Seed)
import Scenario exposing (Scenario, ScenarioMonster, mapTileDataToList, mapTileDataToOverlayList)


type NumPlayers
    = TwoPlayer
    | ThreePlayer
    | FourPlayer


type AIType
    = Enemy Monster
    | Summons Int


type PieceType
    = None
    | Player CharacterClass
    | AI AIType


type alias Piece =
    { ref : PieceType
    , x : Int
    , y : Int
    }


type alias Cell =
    { rooms : List MapTileRef
    , passable : Bool
    }


type alias Game =
    { state : GameState
    , roomOrigins : Dict String ( Int, Int )
    , roomTurns : Dict String Int
    , staticBoard : Array (Array Cell)
    }


type alias GameState =
    { scenario : Int
    , numPlayers : NumPlayers
    , visibleRooms : List MapTileRef
    , overlays : List BoardOverlay
    , pieces : List Piece
    , availableMonsters : Dict String (Array Int)
    }


getPieceType : PieceType -> String
getPieceType piece =
    case piece of
        Player _ ->
            "player"

        AI t ->
            case t of
                Summons _ ->
                    "player"

                Enemy _ ->
                    "monster"

        None ->
            ""


getPieceName : PieceType -> String
getPieceName piece =
    case piece of
        Player p ->
            Maybe.withDefault "" (characterToString p)

        AI t ->
            case t of
                Summons _ ->
                    "summons"

                Enemy e ->
                    Maybe.withDefault "" (monsterTypeToString e.monster)

        None ->
            ""


generateGameMap : Scenario -> NumPlayers -> Seed -> Game
generateGameMap scenario numPlayers seed =
    let
        ( mapTiles, bounds ) =
            mapTileDataToList scenario.mapTilesData Nothing

        availableMonsters =
            map (\m -> ( Maybe.withDefault "" (monsterTypeToString m), initialize (getMonsterBucketSize m) identity )) scenario.additionalMonsters
                |> filter (\( k, _ ) -> k /= "")
                |> map (\( k, v ) -> ( k, Tuple.first (orderRandomArrElement Array.empty seed v) ))
                |> Dict.fromList

        initGameState =
            GameState scenario.id
                numPlayers
                []
                []
                []
                availableMonsters

        initOverlays =
            mapTileDataToOverlayList scenario.mapTilesData

        {- Build a square array capable of holding the whole map
           We add 2 to account for the zero index, and also row drift if the original started on a non-even row
        -}
        arrSize =
            max (abs (bounds.maxX - bounds.minX)) (abs (bounds.maxY - bounds.minY))
                + 1
                + (if Bitwise.and bounds.minY 1 == 1 then
                    1

                   else
                    0
                  )

        -- The Y offset needs adjusting if the start of the original array was an odd row
        offsetY =
            if Bitwise.and bounds.minY 1 == 1 then
                bounds.minY - 1

            else
                bounds.minY

        initMap =
            initialize arrSize (always (initialize arrSize (always (Cell [] False))))

        initGame =
            setCellsFromMapTiles mapTiles initOverlays bounds.minX offsetY seed (Game initGameState Dict.empty Dict.empty initMap)
                |> ensureUniqueOverlays

        startRooms =
            filterMap
                (\o ->
                    case o.ref of
                        StartingLocation ->
                            Just o.cells

                        _ ->
                            Nothing
                )
                initGame.state.overlays
                |> List.foldl (++) []
                |> filterMap (getRoomsByCoord initGame.staticBoard)
                |> List.foldl (++) []
    in
    revealRooms initGame startRooms


setCellsFromMapTiles : List MapTile -> Dict String ( List BoardOverlay, List ScenarioMonster ) -> Int -> Int -> Seed -> Game -> Game
setCellsFromMapTiles mapTileList overlays offsetX offsetY seed game =
    case mapTileList of
        head :: rest ->
            let
                ( newGame, newSeed ) =
                    setCellFromMapTile game overlays offsetX offsetY head seed
            in
            setCellsFromMapTiles rest overlays offsetX offsetY newSeed newGame

        _ ->
            game


setCellFromMapTile : Game -> Dict String ( List BoardOverlay, List ScenarioMonster ) -> Int -> Int -> MapTile -> Seed -> ( Game, Seed )
setCellFromMapTile game overlays offsetX offsetY tile seed =
    let
        x =
            tile.x - offsetX

        y =
            tile.y - offsetY

        refString =
            Maybe.withDefault "" (refToString tile.ref)

        newOrigins =
            if tile.originalX == 0 && tile.originalY == 0 then
                Dict.insert refString ( x, y ) game.roomOrigins

            else
                game.roomOrigins

        state =
            game.state

        ( boardOverlays, piece ) =
            case Dict.get refString overlays of
                Just ( o, m ) ->
                    ( filter (filterByCoord tile.originalX tile.originalY) o
                        |> map (mapOverlayCoord tile.originalX tile.originalY x y tile.turns)
                    , filter (filterMonsterLevel game.state.numPlayers) m
                        |> filter (\f -> f.initialX == tile.originalX && f.initialY == tile.originalY)
                        |> head
                        |> getPieceFromMonster game.state.numPlayers
                        |> mapPieceCoord tile.originalX tile.originalY x y
                    )

                Nothing ->
                    ( [], Piece None 0 0 )

        ( monsterBucket, newSeed ) =
            case piece.ref of
                AI (Enemy m) ->
                    initialize (getMonsterBucketSize m.monster) identity
                        |> orderRandomArrElement Array.empty seed
                        |> (\( a, s ) -> ( Just ( Maybe.withDefault "" (monsterTypeToString m.monster), a ), s ))

                _ ->
                    ( Nothing, seed )

        newGameState =
            { state
                | overlays = game.state.overlays ++ boardOverlays
                , pieces =
                    game.state.pieces
                        ++ (case piece.ref of
                                None ->
                                    []

                                _ ->
                                    [ piece ]
                           )
                , availableMonsters =
                    case monsterBucket of
                        Just b ->
                            b
                                :: Dict.toList game.state.availableMonsters
                                |> filter (\( k, _ ) -> k /= "")
                                |> Dict.fromList

                        _ ->
                            game.state.availableMonsters
            }

        rowArr =
            Array.get y game.staticBoard

        newBoard =
            case rowArr of
                Just yRow ->
                    let
                        cell =
                            Array.get x yRow
                    in
                    case cell of
                        Just foundCell ->
                            let
                                newCell =
                                    { foundCell
                                        | passable =
                                            if foundCell.passable == False then
                                                tile.passable

                                            else
                                                True
                                        , rooms = tile.ref :: foundCell.rooms
                                    }
                            in
                            set y (set x newCell yRow) game.staticBoard

                        Nothing ->
                            game.staticBoard

                Nothing ->
                    game.staticBoard
    in
    ( { game | state = newGameState, staticBoard = newBoard, roomOrigins = newOrigins, roomTurns = Dict.insert refString tile.turns game.roomTurns }
    , newSeed
    )


filterMonsterLevel : NumPlayers -> ScenarioMonster -> Bool
filterMonsterLevel numPlayers monster =
    case numPlayers of
        TwoPlayer ->
            monster.twoPlayer /= Monster.None

        ThreePlayer ->
            monster.threePlayer /= Monster.None

        FourPlayer ->
            monster.fourPlayer /= Monster.None


getLevelForMonster : NumPlayers -> ScenarioMonster -> MonsterLevel
getLevelForMonster numPlayers monster =
    case numPlayers of
        TwoPlayer ->
            monster.twoPlayer

        ThreePlayer ->
            monster.threePlayer

        FourPlayer ->
            monster.fourPlayer


getPieceFromMonster : NumPlayers -> Maybe ScenarioMonster -> Piece
getPieceFromMonster numPlayers monster =
    case monster of
        Just p ->
            let
                m =
                    p.monster
            in
            Piece (AI (Enemy { m | level = getLevelForMonster numPlayers p })) p.initialX p.initialY

        Nothing ->
            Piece None 0 0


getRoomsByCoord : Array (Array Cell) -> ( Int, Int ) -> Maybe (List MapTileRef)
getRoomsByCoord cells ( x, y ) =
    Array.get y cells
        |> Maybe.andThen
            (\colCell ->
                Array.get x colCell
                    |> Maybe.map (\cell -> cell.rooms)
            )


filterByCoord : Int -> Int -> BoardOverlay -> Bool
filterByCoord x y overlay =
    case overlay.cells of
        ( overlayX, overlayY ) :: _ ->
            overlayX == x && overlayY == y

        [] ->
            False


mapPieceCoord : Int -> Int -> Int -> Int -> Piece -> Piece
mapPieceCoord _ _ newX newY piece =
    { piece | x = newX, y = newY }


mapOverlayCoord : Int -> Int -> Int -> Int -> Int -> BoardOverlay -> BoardOverlay
mapOverlayCoord originalX originalY newX newY turns overlay =
    let
        ( oX, oY, oZ ) =
            oddRowToCube ( originalX, originalY )

        ( nX, nY, nZ ) =
            oddRowToCube ( newX, newY )

        diffX =
            nX - oX

        diffY =
            nY - oY

        diffZ =
            nZ - oZ
    in
    { overlay
        | cells =
            map
                (\c ->
                    let
                        ( x1, y1, z1 ) =
                            Hexagon.rotate c ( originalX, originalY ) turns
                                |> oddRowToCube
                    in
                    cubeToOddRow ( diffX + x1, diffY + y1, diffZ + z1 )
                )
                overlay.cells
    }


movePiece : Piece -> Maybe ( Int, Int ) -> ( Int, Int ) -> Game -> ( Game, Piece )
movePiece piece fromCoords ( toX, toY ) game =
    let
        newPiece =
            { piece | x = toX, y = toY }

        gamestate =
            game.state

        newGamestate =
            case fromCoords of
                Just ( fromX, fromY ) ->
                    { gamestate | pieces = filter (removePiece { piece | x = fromX, y = fromY }) gamestate.pieces }

                Nothing ->
                    gamestate
    in
    if canMoveTo ( toX, toY ) { game | state = newGamestate } then
        ( { game | state = { newGamestate | pieces = newPiece :: newGamestate.pieces } }
        , newPiece
        )

    else
        ( game, piece )


revealRooms : Game -> List MapTileRef -> Game
revealRooms game rooms =
    case rooms of
        room :: rest ->
            revealRooms (revealRoom room game) rest

        _ ->
            game


revealRoom : MapTileRef -> Game -> Game
revealRoom room game =
    if member room game.state.visibleRooms then
        game

    else
        let
            roomCells =
                indexedMap (\y arr -> indexedMap (\x cell -> ( cell.rooms, ( x, y ) )) arr) game.staticBoard
                    |> Array.foldl (\a b -> fromList (toList a ++ toList b)) Array.empty
                    |> toList
                    |> filter (\( rooms, _ ) -> member room rooms)
                    |> map (\( _, c ) -> c)

            ( assignedMonsters, availableMonsters ) =
                filterMap
                    (\p ->
                        case p.ref of
                            AI (Enemy _) ->
                                if member ( p.x, p.y ) roomCells then
                                    Just p

                                else
                                    Nothing

                            _ ->
                                Nothing
                    )
                    game.state.pieces
                    |> assignIdentifiers game.state.availableMonsters []
                    |> (\( m, a ) ->
                            ( filterMap
                                (\p ->
                                    case p.ref of
                                        AI (Enemy e) ->
                                            if e.id /= 0 then
                                                Just p

                                            else
                                                Nothing

                                        _ ->
                                            Nothing
                                )
                                m
                            , a
                            )
                       )

            ignoredPieces =
                filterMap
                    (\p ->
                        case p.ref of
                            AI (Enemy _) ->
                                if member ( p.x, p.y ) roomCells then
                                    Nothing

                                else
                                    Just p

                            _ ->
                                Just p
                    )
                    game.state.pieces

            state =
                game.state

            newGame =
                { game | state = { state | visibleRooms = room :: state.visibleRooms, availableMonsters = availableMonsters, pieces = ignoredPieces ++ assignedMonsters } }

            corridors =
                game.state.overlays
                    |> filter
                        (\o ->
                            case o.ref of
                                Door (Corridor _ _) refs ->
                                    member room refs

                                _ ->
                                    False
                        )
                    |> filterMap
                        (\o ->
                            case o.ref of
                                Door (Corridor _ _) refs ->
                                    Just refs

                                _ ->
                                    Nothing
                        )
                    |> foldl (++) []
                    |> filter (\r -> r /= room)
        in
        revealRooms newGame corridors


removePieceFromBoard : Piece -> Game -> Game
removePieceFromBoard piece game =
    let
        gameState =
            game.state

        filteredPieces =
            filter (removePiece piece) gameState.pieces

        newAvailableMonsters =
            case piece.ref of
                AI (Enemy m) ->
                    let
                        ref =
                            Maybe.withDefault "" (monsterTypeToString m.monster)
                    in
                    case Dict.get ref gameState.availableMonsters of
                        Just v ->
                            insert ref (push (m.id - 1) v) gameState.availableMonsters

                        Nothing ->
                            insert ref (fromList [ m.id - 1 ]) gameState.availableMonsters

                _ ->
                    gameState.availableMonsters

        newOverlays =
            case piece.ref of
                AI (Enemy _) ->
                    if
                        any
                            (\o ->
                                case o.ref of
                                    Treasure (Coin _) ->
                                        member ( piece.x, piece.y ) o.cells

                                    _ ->
                                        False
                            )
                            gameState.overlays
                    then
                        map
                            (\o ->
                                case o.ref of
                                    Treasure (Coin i) ->
                                        if member ( piece.x, piece.y ) o.cells then
                                            { o | ref = Treasure (Coin (i + 1)) }

                                        else
                                            o

                                    _ ->
                                        o
                            )
                            gameState.overlays

                    else
                        BoardOverlay (Treasure (Coin 1)) Default [ ( piece.x, piece.y ) ]
                            :: gameState.overlays

                _ ->
                    gameState.overlays
    in
    { game | state = { gameState | pieces = filteredPieces, overlays = newOverlays, availableMonsters = newAvailableMonsters } }


assignIdentifiers : Dict String (Array Int) -> List Piece -> List Piece -> ( List Piece, Dict String (Array Int) )
assignIdentifiers availableMonsters processed monsters =
    case monsters of
        m :: rest ->
            let
                ( newM, newBucket ) =
                    assignIdentifier availableMonsters m
            in
            assignIdentifiers newBucket (newM :: processed) rest

        _ ->
            ( processed, availableMonsters )


assignIdentifier : Dict String (Array Int) -> Piece -> ( Piece, Dict String (Array Int) )
assignIdentifier availableMonsters p =
    case p.ref of
        AI (Enemy monster) ->
            case monsterTypeToString monster.monster of
                Just key ->
                    case Dict.get key availableMonsters of
                        Just bucket ->
                            case Array.get 0 bucket of
                                Just id ->
                                    ( { p | ref = AI (Enemy { monster | id = id + 1 }) }, insert key (slice 1 (length bucket) bucket) availableMonsters )

                                Nothing ->
                                    ( { p | ref = AI (Enemy { monster | id = 0 }) }, availableMonsters )

                        Nothing ->
                            ( { p | ref = AI (Enemy { monster | id = 0 }) }, availableMonsters )

                Nothing ->
                    ( { p | ref = AI (Enemy { monster | id = 0 }) }, availableMonsters )

        _ ->
            ( p, availableMonsters )


moveOverlay : BoardOverlay -> Maybe ( Int, Int ) -> ( Int, Int ) -> Game -> ( Game, BoardOverlay )
moveOverlay overlay _ _ game =
    ( game, overlay )


removePiece : Piece -> Piece -> Bool
removePiece pieceToRemove comparePiece =
    pieceToRemove.ref
        /= comparePiece.ref
        || pieceToRemove.x
        /= comparePiece.x
        || pieceToRemove.y
        /= comparePiece.y


canMoveTo : ( Int, Int ) -> Game -> Bool
canMoveTo ( toX, toY ) game =
    case Array.get toY game.staticBoard of
        Just row ->
            case Array.get toX row of
                Just cell ->
                    if cell.passable then
                        -- TODO : Account for obstacles, account for hidden rooms
                        if any (\p -> p.x == toX && p.y == toY) game.state.pieces then
                            False

                        else
                            True

                    else
                        False

                Nothing ->
                    False

        Nothing ->
            False


orderRandomArrElement : Array a -> Seed -> Array a -> ( Array a, Seed )
orderRandomArrElement bucket seed original =
    if length original == 0 then
        ( bucket, seed )

    else
        let
            ( index, newSeed ) =
                Random.step (Random.int 0 (length original - 1)) seed

            slice1 =
                toList (slice 0 index original)

            slice2 =
                toList (slice (index + 1) (length original) original)
        in
        case Array.get index original of
            Just o ->
                orderRandomArrElement (push o bucket) newSeed (fromList (slice1 ++ slice2))

            Nothing ->
                ( bucket, seed )


assignPlayers : List CharacterClass -> Game -> Game
assignPlayers players game =
    let
        state =
            game.state

        filteredPieces =
            filter
                (\p ->
                    case p.ref of
                        AI (Enemy _) ->
                            True

                        _ ->
                            False
                )
                state.pieces

        statingLocations =
            filter
                (\o ->
                    case o.ref of
                        StartingLocation ->
                            True

                        _ ->
                            False
                )
                state.overlays
    in
    { game | state = { state | pieces = assignPlayersToPiece players filteredPieces statingLocations } }


assignPlayersToPiece : List CharacterClass -> List Piece -> List BoardOverlay -> List Piece
assignPlayersToPiece players pieces startingLocations =
    let
        filteredLocations =
            filter
                (\o ->
                    case o.ref of
                        StartingLocation ->
                            True

                        _ ->
                            False
                )
                startingLocations
    in
    case players of
        player :: rest ->
            case filteredLocations of
                location :: otherLocations ->
                    case head location.cells of
                        Just ( x, y ) ->
                            assignPlayersToPiece rest (Piece (Player player) x y :: pieces) otherLocations

                        Nothing ->
                            pieces

                _ ->
                    pieces

        _ ->
            pieces


ensureUniqueOverlays : Game -> Game
ensureUniqueOverlays game =
    let
        state =
            game.state

        overlays =
            state.overlays
                |> uniqueBy
                    (\o ->
                        cellsToString o.cells ++ getBoardOverlayName o.ref
                    )

        pieces =
            state.pieces
                |> uniqueBy
                    (\p ->
                        String.fromInt p.x ++ "x" ++ String.fromInt p.y
                    )
    in
    { game | state = { state | overlays = overlays, pieces = pieces } }


cellsToString : List ( Int, Int ) -> String
cellsToString cells =
    cells
        |> map (\( x, y ) -> String.fromInt x ++ "x" ++ String.fromInt y)
        |> foldl (\s b -> s ++ "|" ++ b) ""
