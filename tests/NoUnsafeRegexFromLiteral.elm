module NoUnsafeRegexFromLiteral exposing (rule)

{-| Reports the usages of invalid regexes.

@docs rule

-}

import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Range exposing (Range)
import Regex
import Review.ModuleNameLookupTable as ModuleNameLookupTable exposing (ModuleNameLookupTable)
import Review.Rule as Rule exposing (Error, Rule)


{-| Makes sure that regexes built using an unsafe "from literal" function are valid.

You could think as this rule serving to add automated unit tests that check whether the regex is valid.

This rule does several things:

  - Make sure that every call to the target function is passed a literal string (in the code) that represents a valid regex
  - Make sure that the target function is present in the codebase (to make sure we don't lose the guarantees by moving/renaming function)
  - Make sure that the target function is not used in a non-function-call way, so that it's not possible to do `func = targetFunction ; func "(invalid regex"` and use that function in an unsafe way.
  - Report every call to `Regex.fromString` with a static string (so we can feel more confident in those places too)

This follows the ideas and methods proposed in [Safe unsafe operations in Elm](https://jfmengels.net/safe-unsafe-operations-in-elm).


# Configuration

    config =
        [ NoUnsafeRegexFromLiteral.rule
            { unsafeFunction = "Some.Unsafe.Regex.fromLiteral"
            , moduleAlias = Just "RegexUtil"
            }
        ]

`moduleAlias` is the preferred module alias to refer to the unsafe function. It is only used in the error messages.


## Fail

For the example, let's imagine that `Some.Unsafe.Regex.fromLiteral` is the value of the `unsafeFunction` field.

    import Regex
    import Some.Unsafe.Regex

    _ =
        Some.Unsafe.Regex.fromLiteral "(abc|"

    _ =
        Some.Unsafe.Regex.fromLiteral dynamicValue

    copyOfUnsafeFunction =
        Some.Unsafe.Regex.fromLiteral

    _ =
        Regex.fromString "(abc|def)" |> Maybe.withDefault Regex.never

There is also an error if the target function could not be found anywhere in the project.


## Success

    import Regex
    import Some.Unsafe.Regex

    _ =
        Some.Unsafe.Regex.fromLiteral "(abc|def)"

    _ =
        Regex.fromString dynamicValue

-}
rule : { unsafeFunction : String, moduleAlias : Maybe String } -> Rule
rule config =
    let
        target : Target
        target =
            buildTarget config
    in
    Rule.newProjectRuleSchema "NoUnsafeRegexFromLiteral" initialProjectContext
        |> Rule.withElmJsonProjectVisitor elmJsonVisitor
        |> Rule.withModuleVisitor (moduleVisitor target)
        |> Rule.withModuleContextUsingContextCreator
            { fromProjectToModule = fromProjectToModule
            , fromModuleToProject = fromModuleToProject target
            , foldProjectContexts = foldProjectContexts
            }
        |> Rule.withFinalProjectEvaluation (finalProjectEvaluation target)
        |> Rule.fromProjectRuleSchema


buildTarget : { unsafeFunction : String, moduleAlias : Maybe String } -> Target
buildTarget { unsafeFunction, moduleAlias } =
    let
        unsafeFunctionAsList : List String
        unsafeFunctionAsList =
            String.split "." unsafeFunction
                |> List.reverse

        moduleName : List String
        moduleName =
            List.reverse (List.drop 1 unsafeFunctionAsList)

        name : String
        name =
            List.head unsafeFunctionAsList |> Maybe.withDefault "INVALID CONFIGURATION"
    in
    { moduleName = moduleName
    , name = name
    , suggestedImport =
        "import "
            ++ String.join "." moduleName
            ++ (case moduleAlias of
                    Just moduleAlias_ ->
                        " as " ++ moduleAlias_

                    Nothing ->
                        ""
               )
    , suggestedUsage =
        case moduleAlias of
            Just moduleAlias_ ->
                moduleAlias_ ++ "." ++ name

            Nothing ->
                String.join "." moduleName ++ "." ++ name
    }


moduleVisitor : Target -> Rule.ModuleRuleSchema {} ModuleContext -> Rule.ModuleRuleSchema { hasAtLeastOneVisitor : () } ModuleContext
moduleVisitor target schema =
    schema
        |> Rule.withDeclarationListVisitor (declarationListVisitor target)
        |> Rule.withExpressionVisitor (expressionVisitor target)


type alias Target =
    { moduleName : ModuleName
    , name : String
    , suggestedImport : String
    , suggestedUsage : String
    }


type alias ProjectContext =
    { elmJsonKey : Maybe Rule.ElmJsonKey
    , foundTargetFunction : Bool
    }


type alias ModuleContext =
    { lookupTable : ModuleNameLookupTable
    , allowedFunctionOrValues : List Range
    , foundTargetFunction : Bool
    }


initialProjectContext : ProjectContext
initialProjectContext =
    { elmJsonKey = Nothing
    , foundTargetFunction = False
    }


fromProjectToModule : Rule.ContextCreator ProjectContext ModuleContext
fromProjectToModule =
    Rule.initContextCreator
        (\lookupTable _ ->
            { lookupTable = lookupTable
            , allowedFunctionOrValues = []
            , foundTargetFunction = False
            }
        )
        |> Rule.withModuleNameLookupTable


fromModuleToProject : Target -> Rule.ContextCreator ModuleContext ProjectContext
fromModuleToProject target =
    Rule.initContextCreator
        (\metadata moduleContext ->
            { elmJsonKey = Nothing
            , foundTargetFunction = moduleContext.foundTargetFunction && (Rule.moduleNameFromMetadata metadata == target.moduleName)
            }
        )
        |> Rule.withMetadata


foldProjectContexts : ProjectContext -> ProjectContext -> ProjectContext
foldProjectContexts newContext previousContext =
    { elmJsonKey = previousContext.elmJsonKey
    , foundTargetFunction = previousContext.foundTargetFunction || newContext.foundTargetFunction
    }


elmJsonVisitor : Maybe { a | elmJsonKey : Rule.ElmJsonKey } -> ProjectContext -> ( List nothing, ProjectContext )
elmJsonVisitor elmJson projectContext =
    ( [], { projectContext | elmJsonKey = Maybe.map .elmJsonKey elmJson } )


finalProjectEvaluation : Target -> ProjectContext -> List (Error scope)
finalProjectEvaluation target projectContext =
    if projectContext.foundTargetFunction then
        []

    else
        case projectContext.elmJsonKey of
            Just elmJsonKey ->
                [ Rule.errorForElmJson
                    elmJsonKey
                    (\_ ->
                        { message = "Could not find " ++ String.join "." target.moduleName
                        , details =
                            [ "I want to provide guarantees on the use of this function, but I can't find it. It is likely that it was renamed, which prevents me from giving you these guarantees."
                            , "You should rename it back or update this rule to the new name. If you do not use the function anymore, remove the rule."
                            ]
                        , range =
                            { start = { row = 1, column = 1 }
                            , end = { row = 1, column = 2 }
                            }
                        }
                    )
                ]

            Nothing ->
                []


declarationListVisitor : Target -> List (Node Declaration) -> ModuleContext -> ( List nothing, ModuleContext )
declarationListVisitor target nodes moduleContext =
    let
        foundTargetFunction : Bool
        foundTargetFunction =
            List.any
                (\node ->
                    case Node.value node of
                        Declaration.FunctionDeclaration function ->
                            target.name
                                == (function.declaration
                                        |> Node.value
                                        |> .name
                                        |> Node.value
                                   )

                        _ ->
                            False
                )
                nodes
    in
    ( [], { moduleContext | foundTargetFunction = foundTargetFunction } )


isTargetFunction : Target -> ModuleContext -> Node a -> String -> Bool
isTargetFunction target moduleContext functionNode functionName =
    (functionName == target.name)
        && (ModuleNameLookupTable.moduleNameFor moduleContext.lookupTable functionNode == Just target.moduleName)


expressionVisitor : Target -> Node Expression -> Rule.Direction -> ModuleContext -> ( List (Error {}), ModuleContext )
expressionVisitor target node direction moduleContext =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, Expression.Application (function :: argument :: []) ) ->
            case Node.value function of
                Expression.FunctionOrValue _ functionName ->
                    if isTargetFunction target moduleContext function functionName then
                        let
                            errors : List (Error {})
                            errors =
                                case Node.value argument of
                                    Expression.Literal string ->
                                        case Regex.fromString string of
                                            Just _ ->
                                                []

                                            Nothing ->
                                                [ Rule.error (invalidRegex target) (Node.range node) ]

                                    _ ->
                                        [ Rule.error (nonStaticValue target) (Node.range node) ]
                        in
                        ( errors
                        , { moduleContext | allowedFunctionOrValues = Node.range function :: moduleContext.allowedFunctionOrValues }
                        )

                    else if functionName == "fromString" && ModuleNameLookupTable.moduleNameFor moduleContext.lookupTable function == Just [ "Regex" ] then
                        case Node.value argument of
                            Expression.Literal _ ->
                                ( [ Rule.error
                                        { message = "Use `" ++ target.suggestedUsage ++ "` instead"
                                        , details =
                                            [ "By using `" ++ target.suggestedUsage ++ "`, I can make sure that the regex you generated was valid."
                                            , "    " ++ target.suggestedImport ++ "\n    myRegex = " ++ target.suggestedUsage ++ " \"(abc|def)\""
                                            ]
                                        }
                                        (Node.range function)
                                  ]
                                , moduleContext
                                )

                            _ ->
                                ( [], moduleContext )

                    else
                        ( [], moduleContext )

                _ ->
                    ( [], moduleContext )

        ( Rule.OnEnter, Expression.FunctionOrValue _ functionName ) ->
            if
                isTargetFunction target moduleContext node functionName
                    && not (List.member (Node.range node) moduleContext.allowedFunctionOrValues)
            then
                ( [ Rule.error (notUsedAsFunction target) (Node.range node) ]
                , moduleContext
                )

            else
                ( [], moduleContext )

        _ ->
            ( [], moduleContext )


invalidRegex : Target -> { message : String, details : List String }
invalidRegex target =
    { message = String.join "." target.moduleName ++ "." ++ target.name ++ " needs to be called with a valid regex."
    , details =
        [ "This function serves to give you more guarantees about creating regular expressions, but if the argument is dynamic or too complex, I won't be able to tell you."
        , "Note that if you are using a triple-quote string, elm-syntax has a bug where it mis-parses the string and this could be a false report. Switch to using a single-quote string and everything should be fine."
        ]
    }


nonStaticValue : Target -> { message : String, details : List String }
nonStaticValue target =
    { message = String.join "." target.moduleName ++ "." ++ target.name ++ " needs to be called with a static string literal."
    , details =
        [ "This function serves to give you more guarantees about creating regular expressions, but if the argument is dynamic or too complex, I won't be able to tell you."
        , "Either make the argument static or use Regex.fromString instead."
        ]
    }


notUsedAsFunction : Target -> { message : String, details : List String }
notUsedAsFunction target =
    { message = String.join "." target.moduleName ++ "." ++ target.name ++ " must be called directly."
    , details =
        [ "This function serves to give you more guarantees about creating regular expressions, but I can't determine how it is used if you do something else than calling it directly."
        ]
    }
