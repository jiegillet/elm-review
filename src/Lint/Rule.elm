module Lint.Rule exposing
    ( Rule, Schema
    , newSchema, fromSchema
    , withSimpleModuleDefinitionVisitor, withSimpleImportVisitor, withSimpleDeclarationVisitor, withSimpleExpressionVisitor
    , withInitialContext, withModuleDefinitionVisitor, withImportVisitor, withDeclarationVisitor, withExpressionVisitor, withFinalEvaluation
    , name, analyzer
    )

{-| This module contains functions that are used for writing rules.

TODO Explain how traversal works, and what an AST is.
TODO Explain the order of traversal: moduleDefinition -> imports -> declarations + expressions -> final evaluation
TODO Explain that and why people need to look at the documentation for elm-syntax.


# Definition

@docs Rule, Schema


# Writing rules

@docs newSchema, fromSchema
@docs withSimpleModuleDefinitionVisitor, withSimpleImportVisitor, withSimpleDeclarationVisitor, withSimpleExpressionVisitor
@docs withInitialContext, withModuleDefinitionVisitor, withImportVisitor, withDeclarationVisitor, withExpressionVisitor, withFinalEvaluation


# ACCESS

@docs name, analyzer

-}

import Elm.Syntax.Declaration exposing (Declaration)
import Elm.Syntax.Expression exposing (Expression)
import Elm.Syntax.File exposing (File)
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Module exposing (Module)
import Elm.Syntax.Node exposing (Node)
import Lint.Direction as Direction exposing (Direction)
import Lint.Error exposing (Error)
import Lint.Internal.Accumulate exposing (accumulateList)
import Lint.Internal.DeclarationVisitor as DeclarationVisitor


{-| Represents a construct able to analyze a `File` and report unwanted patterns.
See [`newSchema`](#newSchema), and [`fromSchema`](#fromSchema) for how to create one.
-}
type Rule
    = Rule
        { name : String
        , analyzer : File -> List Error
        }


{-| Represents a Schema for a [`Rule`](#Rule). Create one using [`newSchema`](#newSchema).

    import Lint.Rule as Rule exposing (Rule)

    rule : Rule
    rule =
        Rule.newSchema "NoDebug"
            |> Rule.withExpressionVisitor expressionVisitor
            |> Rule.fromSchema

-}
type Schema context
    = Schema
        { name : String
        , initialContext : context
        , moduleDefinitionVisitor : Node Module -> context -> ( List Error, context )
        , importVisitor : Node Import -> context -> ( List Error, context )
        , expressionVisitor : Node Expression -> Direction -> context -> ( List Error, context )
        , declarationVisitor : Node Declaration -> Direction -> context -> ( List Error, context )
        , finalEvaluationFn : context -> List Error
        }


{-| Creates a new schema for a rule. Will require calling [`fromSchema`](#fromSchema)
to create a usable [`Rule`](#Rule). Use "with\*" functions from this module, like
[`withSimpleExpressionVisitor`](#withSimpleExpressionVisitor) or [`withSimpleImportVisitor`](#withSimpleImportVisitor)
to make it report something.

    import Lint.Rule as Rule exposing (Rule)

    rule : Rule
    rule =
        Rule.newSchema "NoDebug"
            |> Rule.withSimpleExpressionVisitor expressionVisitor
            |> Rule.withSimpleImportVisitor importVisitor
            |> Rule.fromSchema

If you wish to build a [`Rule`](#Rule) that collects data as the file gets traversed,
take a look at [`withInitialContext`](#withInitialContext) and "with\*" functions without
"Simple" in their name, like [`withExpressionVisitor`](#withExpressionVisitor),
[`withImportVisitor`](#withImportVisitor) or [`withFinalEvaluation`](#withFinalEvaluation).

    import Lint.Rule as Rule exposing (Rule)

    rule : Rule
    rule =
        Rule.newSchema "NoUnusedVariables"
            |> Rule.withInitialContext { declaredVariables = [], usedVariables = [] }
            |> Rule.withExpressionVisitor expressionVisitor
            |> Rule.withImportVisitor importVisitor
            |> Rule.fromSchema

-}
newSchema : String -> Schema ()
newSchema name_ =
    Schema
        { name = name_
        , initialContext = ()
        , moduleDefinitionVisitor = \node context -> ( [], context )
        , importVisitor = \node context -> ( [], context )
        , expressionVisitor = \direction node context -> ( [], context )
        , declarationVisitor = \direction node context -> ( [], context )
        , finalEvaluationFn = \context -> []
        }


{-| Create a [`Rule`](#Rule) from a configured [`Schema`](#Schema).
-}
fromSchema : Schema context -> Rule
fromSchema (Schema schema) =
    Rule
        { name = schema.name
        , analyzer =
            \file ->
                schema.initialContext
                    |> schema.moduleDefinitionVisitor file.moduleDefinition
                    |> accumulateList schema.importVisitor file.imports
                    |> accumulateList (DeclarationVisitor.visit schema.declarationVisitor schema.expressionVisitor) file.declarations
                    |> makeFinalEvaluation schema.finalEvaluationFn
                    |> List.reverse
        }


{-| Concatenate the errors of the previous step and of the last step.
-}
makeFinalEvaluation : (context -> List Error) -> ( List Error, context ) -> List Error
makeFinalEvaluation finalEvaluationFn ( previousErrors, previousContext ) =
    finalEvaluationFn previousContext
        ++ previousErrors


{-| Add a visitor to the [`Schema`](#Schema) which will visit the `File`'s [module definition](https://package.elm-lang.org/packages/stil4m/elm-syntax/latest/Elm-Syntax-Module) (`module SomeModuleName exposing (a, b)`) and report patterns.

The following example forbids having `_` in any part of a module name.

    import Elm.Syntax.Module as Module exposing (Module)
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    rule : Rule
    rule =
        Rule.newSchema "NoUnderscoreInModuleName"
            |> Rule.withSimpleModuleDefinitionVisitor moduleDefinitionVisitor
            |> Rule.fromSchema

    moduleDefinitionVisitor : Node Module -> List Error
    moduleDefinitionVisitor node =
        if List.any (String.contains "") (Node.value node |> Module.moduleName) then
            [ Error.create "Do not use `_` in a module name" (Node.range node) ]

        else
            []

Note: `withSimpleModuleDefinitionVisitor` is a simplified version of [`withModuleDefinitionVisitor`](#withModuleDefinitionVisitor),
which isn't passed a `context` and doesn't return one. You can use `withSimpleModuleDefinitionVisitor` even if you use "non-simple with\*" functions.

-}
withSimpleModuleDefinitionVisitor : (Node Module -> List Error) -> Schema context -> Schema context
withSimpleModuleDefinitionVisitor visitor (Schema schema) =
    Schema { schema | moduleDefinitionVisitor = \node context -> ( visitor node, context ) }


{-| Add a visitor to the [`Schema`](#Schema) which will visit the `File`'s [import statements](https://package.elm-lang.org/packages/stil4m/elm-syntax/latest/Elm-Syntax-Import) (`import Html as H exposing (div)`) in order of their definition and report patterns.

The following example forbids using the core Html package and suggests using
`elm-css` or `elm-ui` instead.

    import Elm.Syntax.Import exposing (Import)
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    rule : Rule
    rule =
        Rule.newSchema "NoCoreHtml"
            |> Rule.withSimpleImportVisitor importVisitor
            |> Rule.fromSchema

    importVisitor : Node Import -> List Error
    importVisitor node =
        let
            moduleName : List String
            moduleName =
                node
                    |> Node.value
                    |> .moduleName
                    |> Node.value
        in
        case moduleName of
            [ "Html" ] ->
                [ Error.create "Use `elm-css` or `elm-ui` instead of the core HTML package." (Node.range node) ]

            _ ->
                []

Note: `withSimpleImportVisitor` is a simplified version of [`withImportVisitor`](#withImportVisitor),
which isn't passed a `context` and doesn't return one. You can use `withSimpleImportVisitor` even if you use "non-simple with\*" functions.

-}
withSimpleImportVisitor : (Node Import -> List Error) -> Schema context -> Schema context
withSimpleImportVisitor visitor (Schema schema) =
    Schema { schema | importVisitor = \node context -> ( visitor node, context ) }


{-| Add a visitor to the [`Schema`](#Schema) which will visit the `File`'s
[declaration statements](https://package.elm-lang.org/packages/stil4m/elm-syntax/latest/Elm-Syntax-Declaration)
(`someVar = add 1 2`, `type Bool = True | False`, `port output : Json.Encode.Value -> Cmd msg`)
and report patterns. The declarations will be visited in the order of their definition.

The following example forbids declaring a function or a value without a type
annotation.

    import Elm.Syntax.Declaration exposing (Declaration(..))
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    rule : Rule
    rule =
        Rule.newSchema "NoMissingTypeAnnotation"
            |> Rule.withSimpleDeclarationVisitor declarationVisitor
            |> Rule.fromSchema

    declarationVisitor : Node Declaration -> List Error
    declarationVisitor node =
        case Node.value node of
            FunctionDeclaration { signature, declaration } ->
                case signature of
                    Just _ ->
                        []

                    Nothing ->
                        let
                            functionName : String
                            functionName =
                                declaration |> Node.value |> .name |> Node.value
                        in
                        [ Error.create ("Missing type annotation for `" ++ functionName ++ "`.") (Node.range node) ]

            _ ->
                []

Note: `withSimpleDeclarationVisitor` is a simplified version of [`withDeclarationVisitor`](#withDeclarationVisitor),
which isn't passed a `Direction` (it will only be called on `Direction.Enter`) and a `context` and doesn't return a context. You can use `withSimpleDeclarationVisitor` even if you use "non-simple with\*" functions.

-}
withSimpleDeclarationVisitor : (Node Declaration -> List Error) -> Schema context -> Schema context
withSimpleDeclarationVisitor visitor (Schema schema) =
    Schema
        { schema
            | declarationVisitor =
                \node direction context ->
                    case direction of
                        Direction.Enter ->
                            ( visitor node, context )

                        Direction.Exit ->
                            ( [], context )
        }


{-| Add a visitor to the [`Schema`](#Schema) which will visit the `File`'s
[expressions](https://package.elm-lang.org/packages/stil4m/elm-syntax/latest/Elm-Syntax-Expression)
(`1`, `True`, `add 1 2`, `1 + 2`). The expressions are visited in pre-order
depth-first search, meaning that an expression will be visited, then it's first
child, the first child's children (and so on), then the second child (and so on).

The following example forbids using the Debug module.

    import Elm.Syntax.Expression exposing (Expression(..))
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    rule : Rule
    rule =
        Rule.newSchema "NoDebug"
            |> Rule.withSimpleExpressionVisitor expressionVisitor
            |> Rule.fromSchema

    expressionVisitor : Node Expression -> List Error
    expressionVisitor node =
        case Node.value node of
            FunctionOrValue moduleName fnName ->
                if List.member "Debug" moduleName then
                    [ Error.create "Forbidden use of Debug" (Node.range node) ]

                else
                    []

            _ ->
                []

Note: `withSimpleExpressionVisitor` is a simplified version of [`withExpressionVisitor`](#withExpressionVisitor),
which isn't passed a `Direction` (it will only be called on `Direction.Enter`) and a `context` and doesn't return a context. You can use `withSimpleExpressionVisitor` even if you use "non-simple with\*" functions.

-}
withSimpleExpressionVisitor : (Node Expression -> List Error) -> Schema context -> Schema context
withSimpleExpressionVisitor visitor (Schema schema) =
    Schema
        { schema
            | expressionVisitor =
                \node direction context ->
                    case direction of
                        Direction.Enter ->
                            ( visitor node, context )

                        Direction.Exit ->
                            ( [], context )
        }


{-| Adds an initial `context` to start collecting data during your traversal.

In some cases, you can't just report a pattern when you see it, but you want to
not report or report differently depending on information located in a different
part of the file. In that case, you collect data as the nodes in the file get
traversed and store it in what we'll call a `context`. This `context` will be
available and updated by non-"simple" "with\*" functions, like
[`withExpressionVisitor`](#withExpressionVisitor) or [`withImportVisitor`](#withImportVisitor).

Once the file has been traversed and you have collected all the data available
from the file, you can report some final errors using [`withFinalEvaluation`](#withFinalEvaluation).

A few use examples:

  - You want to report the use of `Debug.log`: and if you see a call using a `log`
    function, you need to check whether `log` was defined in the file, or imported
    using `import Debug exposing (log)` or `import Debug exposing (..)`.
  - You wish to report unused variables, so you need to register the declared and
    imported variables, and note when they get used.
  - You noticed plenty of bad or inconsistent uses of the `Html.button` function,
    so you built a nice `Ui.Button` module. You now want to forbid all uses of
    `Html.button`, except in the `Ui.Button` module.

The `context` you choose needs to be of the same type for all visitors. In practice,
it's similar to a `Model` for a rule.

The following example forbids calling `Rule.newSchema` with a name that is not
the same as the module's name (forbidding `Rule.newSchema "NoSomething"` when the
module name is `Lint.Rule.NoSomethingElse`).

    -- module Lint.Rule.NoDifferentNameForRuleAndModuleName exposing (rule)


    import Elm.Syntax.Expression exposing (Expression(..))
    import Elm.Syntax.Module as Module exposing (Module)
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Direction as Direction exposing (Direction)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)
    import List.Extra

    type alias Context =
        -- Contains the module name's last part
        Maybe String

    rule : Rule
    rule =
        Rule.newSchema "NoDifferentNameForRuleAndModuleName"
            |> Rule.withInitialContext Nothing
            |> Rule.withModuleDefinitionVisitor moduleDefinitionVisitor
            |> Rule.withExpressionVisitor expressionVisitor
            |> Rule.fromSchema

    moduleDefinitionVisitor : Node Module -> Context -> ( List Error, Context )
    moduleDefinitionVisitor node context =
        let
            moduleLastName : Maybe String
            moduleLastName =
                node
                    |> Node.value
                    |> Module.moduleName
                    |> List.Extra.last
        in
        ( [], moduleLastName )

    expressionVisitor : Node Expression -> Direction -> Context -> ( List Error, Context )
    expressionVisitor node direction context =
        case ( direction, Node.value node ) of
            ( Direction.Enter, Application (function :: ruleNameNode :: _) ) ->
                case ( Node.value function, Node.value ruleNameNode ) of
                    ( FunctionOrValue [ "Rule" ] "newSchema", Literal ruleName ) ->
                        if Just ruleName /= context then
                            let
                                suggestedName : String
                                suggestedName =
                                    case context of
                                        Just name ->
                                            " (`" ++ name ++ "`)"

                                        Nothing ->
                                            ""
                            in
                            ( [ Error.create
                                    ("Rule name should be the same as the module name" ++ suggestedName)
                                    (Node.range ruleNameNode)
                              ]
                            , context
                            )

                        else
                            ( [], context )

                    _ ->
                        ( [], context )

            _ ->
                ( [], context )

Note that due to implementation details, `withInitialContext` needs to be chained
right after [`newSchema`](#newSchema) just like in the example above, as previous
"with\*" functions will be ignored.

-}
withInitialContext : context -> Schema () -> Schema context
withInitialContext initialContext_ (Schema schema) =
    Schema
        { name = schema.name
        , initialContext = initialContext_
        , moduleDefinitionVisitor = \node context -> ( [], context )
        , importVisitor = \node context -> ( [], context )
        , expressionVisitor = \node direction context -> ( [], context )
        , declarationVisitor = \node direction context -> ( [], context )
        , finalEvaluationFn = \context -> []
        }


{-| Add a visitor to the [`Schema`](#Schema) which will visit the `File`'s
[module definition](https://package.elm-lang.org/packages/stil4m/elm-syntax/latest/Elm-Syntax-Module) (`module SomeModuleName exposing (a, b)`), collect data in the `context` and/or report patterns.

The following example forbids the use of `Debug` except in some files, determined
by a configuration which could look like `( Critical, NoDebugExceptInSomeModules.rule ["Some.Module"] )`

    import Elm.Syntax.Expression exposing (Expression(..))
    import Elm.Syntax.Module as Module exposing (Module)
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Direction as Direction exposing (Direction)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    type Context
        = DebugIsAllowed
        | DebugIsForbidden

    rule : List String -> Rule
    rule allowedModuleNames =
        Rule.newSchema "NoDebugExceptInSomeModules"
            |> Rule.withInitialContext DebugIsForbidden
            |> Rule.withModuleDefinitionVisitor
                (moduleDefinitionVisitor <| List.map (String.split ".") allowedModuleNames)
            |> Rule.withExpressionVisitor expressionVisitor
            |> Rule.fromSchema

    moduleDefinitionVisitor : List (List String) -> Node Module -> Context -> ( List Error, Context )
    moduleDefinitionVisitor allowedModuleNames node context =
        if List.member (Node.value node |> Module.moduleName) allowedModuleNames then
            ( [], DebugIsAllowed )

        else
            ( [], DebugIsForbidden )

    expressionVisitor : Node Expression -> Direction -> Context -> ( List Error, Context )
    expressionVisitor node direction context =
        case ( direction, context ) of
            ( Direction.Enter, DebugIsAllowed ) ->
                ( [], context )

            ( Direction.Enter, DebugIsForbidden ) ->
                case Node.value node of
                    FunctionOrValue moduleName fnName ->
                        if List.member "Debug" moduleName then
                            ( [ Error.create "Forbidden use of Debug" (Node.range node) ], context )

                        else
                            ( [], context )

                    _ ->
                        ( [], context )

            ( _, _ ) ->
                ( [], context )

Note: If you do not need to collect data in this visitor, you may wish to use the
simpler [`withSimpleModuleDefinitionVisitor`](#withSimpleModuleDefinitionVisitor).

-}
withModuleDefinitionVisitor : (Node Module -> context -> ( List Error, context )) -> Schema context -> Schema context
withModuleDefinitionVisitor visitor (Schema schema) =
    Schema { schema | moduleDefinitionVisitor = visitor }


{-| Add a visitor to the [`Schema`](#Schema) which will visit the `File`'s
[import statements](https://package.elm-lang.org/packages/stil4m/elm-syntax/latest/Elm-Syntax-Import)
(`import Html as H exposing (div)`) in order of their definition, collect data
in the `context` and/or report patterns.

The following example forbids importing both `Element` (`elm-ui`) and
`Html.Styled` (`elm-css`).

    import Elm.Syntax.Import exposing (Import)
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    type alias Context =
        { elmUiWasImported : Bool
        , elmCssWasImported : Bool
        }

    rule : Rule
    rule =
        Rule.newSchema "NoUsingBothHtmlAndHtmlStyled"
            |> Rule.withInitialContext { elmUiWasImported = False, elmCssWasImported = False }
            |> Rule.withImportVisitor importVisitor
            |> Rule.fromSchema

    importVisitor : Node Import -> Context -> ( List Error, Context )
    importVisitor node context =
        case Node.value node |> .moduleName |> Node.value of
            [ "Element" ] ->
                if context.elmCssWasImported then
                    ( [ Error.create "Do not use both `elm-ui` and `elm-css`" (Node.range node) ]
                    , { context | elmUiWasImported = True }
                    )

                else
                    ( [ Error.create "Do not use both `elm-ui` and `elm-css`" (Node.range node) ]
                    , { context | elmUiWasImported = True }
                    )

            [ "Html", "Styled" ] ->
                if context.elmUiWasImported then
                    ( [ Error.create "Do not use both `elm-ui` and `elm-css`" (Node.range node) ]
                    , { context | elmCssWasImported = True }
                    )

                else
                    ( [ Error.create "Do not use both `elm-ui` and `elm-css`" (Node.range node) ]
                    , { context | elmCssWasImported = True }
                    )

            _ ->
                ( [], context )

This example was written in a different way in the example for [`withFinalEvaluation`](#withFinalEvaluation).

Note: If you do not need to collect or use the `context` in this visitor, you may wish to use the
simpler [`withSimpleImportVisitor`](#withSimpleImportVisitor).

-}
withImportVisitor : (Node Import -> context -> ( List Error, context )) -> Schema context -> Schema context
withImportVisitor visitor (Schema schema) =
    Schema { schema | importVisitor = visitor }


{-| Add a visitor to the [`Schema`](#Schema) which will visit the `File`'s
[declaration statements](https://package.elm-lang.org/packages/stil4m/elm-syntax/latest/Elm-Syntax-Declaration)
(`someVar = add 1 2`, `type Bool = True | False`, `port output : Json.Encode.Value -> Cmd msg`),
collect data and/or report patterns. The declarations will be visited in the order of their definition.

The following example forbids declaring a function or a value without a type
annotation.

    import Elm.Syntax.Declaration exposing (Declaration(..))
    import Elm.Syntax.Exposing as Exposing
    import Elm.Syntax.Module as Module exposing (Module)
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Direction as Direction exposing (Direction)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    type ExposedFunctions
        = All
        | OnlySome (List String)

    rule : Rule
    rule =
        Rule.newSchema "NoMissingDocumentationForExposedFunctions"
            |> Rule.withInitialContext (OnlySome [])
            |> Rule.withModuleDefinitionVisitor moduleDefinitionVisitor
            |> Rule.withDeclarationVisitor declarationVisitor
            |> Rule.fromSchema

    moduleDefinitionVisitor : Node Module -> ExposedFunctions -> ( List Error, ExposedFunctions )
    moduleDefinitionVisitor node context =
        case Node.value node |> Module.exposingList of
            Exposing.All _ ->
                ( [], All )

            Exposing.Explicit exposedValues ->
                ( [], OnlySome (List.filterMap exposedFunctionName exposedValues) )

    exposedFunctionName : Node Exposing.TopLevelExpose -> Maybe String
    exposedFunctionName value =
        case Node.value value of
            Exposing.FunctionExpose functionName ->
                Just functionName

            _ ->
                Nothing

    declarationVisitor : Node Declaration -> Direction -> ExposedFunctions -> ( List Error, ExposedFunctions )
    declarationVisitor node direction context =
        case ( direction, Node.value node ) of
            ( Direction.Enter, FunctionDeclaration { documentation, declaration } ) ->
                let
                    functionName : String
                    functionName =
                        Node.value declaration |> .name |> Node.value
                in
                if documentation == Nothing && isExposed context functionName then
                    ( [ Error.create "Exposed function is missing a type annotation" (Node.range node) ], context )

                else
                    ( [], context )

            _ ->
                ( [], context )

    isExposed : ExposedFunctions -> String -> Bool
    isExposed exposedFunctions name =
        case exposedFunctions of
            All ->
                True

            OnlySome exposedList ->
                List.member name exposedList

Note: If you do not need to collect or use the `context` in this visitor, you may wish to use the
simpler [`withSimpleDeclarationVisitor`](#withSimpleDeclarationVisitor).

-}
withDeclarationVisitor : (Node Declaration -> Direction -> context -> ( List Error, context )) -> Schema context -> Schema context
withDeclarationVisitor visitor (Schema schema) =
    Schema { schema | declarationVisitor = visitor }


{-| Add a visitor to the [`Schema`](#Schema) which will visit the `File`'s
[expressions](https://package.elm-lang.org/packages/stil4m/elm-syntax/latest/Elm-Syntax-Expression)
(`1`, `True`, `add 1 2`, `1 + 2`), collect data in the `context` and/or report patterns.
The expressions are visited in pre-order depth-first search, meaning that an
expression will be visited, then it's first child, the first child's children
(and so on), then the second child (and so on).

The following example forbids the use of `Debug.log` even when it's imported like
`import Debug exposing (log)`.
module Main exposing (Context(..), expressionVisitor, importVisitor, rule)

    import Elm.Syntax.Exposing as Exposing exposing (TopLevelExpose(..))
    import Elm.Syntax.Expression exposing (Expression(..))
    import Elm.Syntax.Import exposing (Import)
    import Elm.Syntax.Node as Node exposing (Node)
    import Lint.Direction as Direction exposing (Direction)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    type Context
        = DebugLogWasNotImported
        | DebugLogWasImported

    rule : Rule
    rule =
        Rule.newSchema "NoDebugEvenIfImported"
            |> Rule.withInitialContext DebugLogWasNotImported
            |> Rule.withImportVisitor importVisitor
            |> Rule.withExpressionVisitor expressionVisitor
            |> Rule.fromSchema

    importVisitor : Node Import -> Context -> ( List Error, Context )
    importVisitor node context =
        case ( Node.value node |> .moduleName |> Node.value, (Node.value node).exposingList |> Maybe.map Node.value ) of
            ( [ "Debug" ], Just (Exposing.All _) ) ->
                ( [], DebugLogWasImported )

            ( [ "Debug" ], Just (Exposing.Explicit exposedFunctions) ) ->
                let
                    isLogFunction : Node Exposing.TopLevelExpose -> Bool
                    isLogFunction exposeNode =
                        case Node.value exposeNode of
                            FunctionExpose "log" ->
                                True

                            _ ->
                                False
                in
                if List.any isLogFunction exposedFunctions then
                    ( [], DebugLogWasImported )

                else
                    ( [], DebugLogWasNotImported )

            _ ->
                ( [], DebugLogWasNotImported )

    expressionVisitor : Node Expression -> Direction -> Context -> ( List Error, Context )
    expressionVisitor node direction context =
        case context of
            DebugLogWasNotImported ->
                ( [], context )

            DebugLogWasImported ->
                case ( direction, Node.value node ) of
                    ( Direction.Enter, FunctionOrValue [] "log" ) ->
                        ( [ Error.create "Forbidden use of Debug.log" (Node.range node) ], context )

                    _ ->
                        ( [], context )

Note: If you do not need to collect or use the `context` in this visitor, you may wish to use the
simpler [`withSimpleExpressionVisitor`](#withSimpleExpressionVisitor).

-}
withExpressionVisitor : (Node Expression -> Direction -> context -> ( List Error, context )) -> Schema context -> Schema context
withExpressionVisitor visitor (Schema schema) =
    Schema { schema | expressionVisitor = visitor }


{-| Add a function that makes a final evaluation based only on the data that was
collected in the `context`. This can be useful if you can't or if it is hard to
determine something as you traverse the file.

This example was written in a different way in the example for [`withFinalEvaluation`](#withFinalEvaluation).

The following example forbids importing both `Element` (`elm-ui`) and
`Html.Styled` (`elm-css`). Note that this is the same one written in the example
for [`withImportVisitor`](#withImportVisitor), but using `withFinalEvaluation`.

    import Dict as Dict exposing (Dict)
    import Elm.Syntax.Import exposing (Import)
    import Elm.Syntax.Node as Node exposing (Node)
    import Elm.Syntax.Range exposing (Range)
    import Lint.Error as Error exposing (Error)
    import Lint.Rule as Rule exposing (Rule)

    type alias Context =
        Dict (List String) Range

    rule : Rule
    rule =
        Rule.newSchema "NoUsingBothHtmlAndHtmlStyled"
            |> Rule.withInitialContext Dict.empty
            |> Rule.withImportVisitor importVisitor
            |> Rule.withFinalEvaluation finalEvaluation
            |> Rule.fromSchema

    importVisitor : Node Import -> Context -> ( List Error, Context )
    importVisitor node context =
        ( [], Dict.insert (Node.value node |> .moduleName |> Node.value) (Node.range node) context )

    finalEvaluation : Context -> List Error
    finalEvaluation context =
        case ( Dict.get [ "Element" ] context, Dict.get [ "Html", "Styled" ] context ) of
            ( Just elmUiRange, Just _ ) ->
                [ Error.create "Do not use both `elm-ui` and `elm-css`" elmUiRange ]

            _ ->
                []

-}
withFinalEvaluation : (context -> List Error) -> Schema context -> Schema context
withFinalEvaluation visitor (Schema schema) =
    Schema { schema | finalEvaluationFn = visitor }



-- ACCESS


{-| Get the name of a [`Rule`](#Rule).
-}
name : Rule -> String
name (Rule rule) =
    rule.name


{-| Get the analyzer function of a [`Rule`](#Rule).
-}
analyzer : Rule -> (File -> List Error)
analyzer (Rule rule) =
    rule.analyzer
