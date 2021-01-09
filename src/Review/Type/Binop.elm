module Review.Type.Binop exposing
    ( Binop
    , associativity
    , documentation
    , fromElmDocs
    , name
    , precedence
    , tipe
    , toElmDocs
    )

import Elm.Docs
import Review.Type as Type



-- TODO Expose module, but hide implementation and type inside an "Internal" module


type Binop
    = Binop
        { name : String
        , documentation : Maybe String
        , tipe : Maybe Type.Type
        , associativity : Elm.Docs.Associativity
        , precedence : Int
        }


fromElmDocs : Elm.Docs.Binop -> Binop
fromElmDocs binop =
    Binop
        { name = binop.name
        , documentation = Just binop.comment
        , tipe = Just (Type.fromElmDocs binop.tipe)
        , associativity = binop.associativity
        , precedence = binop.precedence
        }


toElmDocs : Binop -> Maybe Elm.Docs.Binop
toElmDocs (Binop binop) =
    Maybe.map2
        (\documentation_ tipe_ ->
            { name = binop.name
            , comment = documentation_
            , tipe = tipe_
            , associativity = binop.associativity
            , precedence = binop.precedence
            }
        )
        binop.documentation
        (Maybe.andThen Type.toElmDocs binop.tipe)


name : Binop -> String
name (Binop binop) =
    binop.name


documentation : Binop -> Maybe String
documentation (Binop binop) =
    binop.documentation


tipe : Binop -> Maybe Type.Type
tipe (Binop binop) =
    binop.tipe


associativity : Binop -> Elm.Docs.Associativity
associativity (Binop binop) =
    binop.associativity


precedence : Binop -> Int
precedence (Binop binop) =
    binop.precedence
