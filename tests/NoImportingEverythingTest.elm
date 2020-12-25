module NoImportingEverythingTest exposing (all)

import NoImportingEverything exposing (rule)
import Review.Test
import Test exposing (Test, describe, test)


all : Test
all =
    describe "NoImportingEverything"
        [ withoutModuleInformationTests
        , withModuleInformationTests
        ]


withoutModuleInformationTests : Test
withoutModuleInformationTests =
    describe "Without module information"
        [ test "should not report imports without exposing clause" <|
            \_ ->
                """module A exposing (thing)
import Html
import Html as B
"""
                    |> Review.Test.run (rule [])
                    |> Review.Test.expectNoErrors
        , test "should not report imports that expose some elements" <|
            \_ ->
                """module A exposing (thing)
import Html exposing (B, c)
"""
                    |> Review.Test.run (rule [])
                    |> Review.Test.expectNoErrors
        , test "should not report imports that expose all constructors of a type" <|
            \_ ->
                """module A exposing (thing)
import Html exposing (B(..))
"""
                    |> Review.Test.run (rule [])
                    |> Review.Test.expectNoErrors
        , test "should report imports that expose everything" <|
            \_ ->
                """module A exposing (thing)
import Html exposing (..)
"""
                    |> Review.Test.run (rule [])
                    |> Review.Test.expectErrors
                        [ Review.Test.error
                            { message = "Prefer listing what you wish to import and/or using qualified imports"
                            , details = [ "When you import everything from a module it becomes harder to know where a function or a type comes from." ]
                            , under = "(..)"
                            }
                        ]
        , test "should not report imports that are in the exceptions list" <|
            \_ ->
                """module A exposing (thing)
import Html exposing (..)
import Thing.Foo as Foo exposing (..)
"""
                    |> Review.Test.run (rule [ "Html", "Thing.Foo" ])
                    |> Review.Test.expectNoErrors
        ]


withModuleInformationTests : Test
withModuleInformationTests =
    describe "With module information"
        [ test "should fix imports that expose everything" <|
            \_ ->
                [ """module A exposing (thing)
import OtherModule exposing (..)
b = a
""", """module OtherModule exposing (..)
a = 1
""" ]
                    |> Review.Test.runOnModules (rule [])
                    |> Review.Test.expectErrorsForModules
                        [ ( "A"
                          , [ Review.Test.error
                                { message = "Prefer listing what you wish to import and/or using qualified imports"
                                , details = [ "When you import everything from a module it becomes harder to know where a function or a type comes from." ]
                                , under = "(..)"
                                }
                                |> Review.Test.whenFixed """module A exposing (thing)
import OtherModule exposing (a)
b = a
"""
                            ]
                          )
                        ]
        , test "should only replace by imports used in an unqualified manner" <|
            \_ ->
                [ """module A exposing (thing)
import OtherModule exposing (..)
b = OtherModule.c a
""", """module OtherModule exposing (..)
a = 1
c = 2
""" ]
                    |> Review.Test.runOnModules (rule [])
                    |> Review.Test.expectErrorsForModules
                        [ ( "A"
                          , [ Review.Test.error
                                { message = "Prefer listing what you wish to import and/or using qualified imports"
                                , details = [ "When you import everything from a module it becomes harder to know where a function or a type comes from." ]
                                , under = "(..)"
                                }
                                |> Review.Test.whenFixed """module A exposing (thing)
import OtherModule exposing (a)
b = OtherModule.c a
"""
                            ]
                          )
                        ]
        , test "should not touch fix unused exposing (..) if nothing was used" <|
            \_ ->
                [ """module A exposing (thing)
import OtherModule exposing (..)
b = c
""", """module OtherModule exposing (..)
a = 1
""" ]
                    |> Review.Test.runOnModules (rule [])
                    |> Review.Test.expectErrorsForModules
                        [ ( "A"
                          , [ Review.Test.error
                                { message = "Prefer listing what you wish to import and/or using qualified imports"
                                , details = [ "When you import everything from a module it becomes harder to know where a function or a type comes from." ]
                                , under = "(..)"
                                }
                            ]
                          )
                        ]
        ]
