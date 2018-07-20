module Page.Group
    exposing
        ( Model
        , Msg(..)
        , init
        , setup
        , teardown
        , update
        , subscriptions
        , view
        , handlePostCreated
        , handleReplyCreated
        , handleGroupMembershipUpdated
        )

import Date exposing (Date)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Task exposing (Task)
import Time exposing (Time, every, second, millisecond)
import Autosize
import Avatar exposing (personAvatar)
import Component.Post
import Connection exposing (Connection)
import Data.Group exposing (Group)
import Data.GroupMembership exposing (GroupMembership, GroupMembershipState(..))
import Data.Post exposing (Post)
import Data.Reply exposing (Reply)
import Data.Space exposing (Space)
import Data.SpaceUser exposing (SpaceUser)
import Data.ValidationError exposing (ValidationError)
import Keys exposing (Modifier(..), preventDefault, onKeydown, enter, esc)
import Mutation.PostToGroup as PostToGroup
import Mutation.UpdateGroup as UpdateGroup
import Mutation.UpdateGroupMembership as UpdateGroupMembership
import Ports
import Query.FeaturedMemberships as FeaturedMemberships
import Query.GroupInit as GroupInit
import Repo exposing (Repo)
import Route
import Session exposing (Session)
import Subscription.GroupSubscription as GroupSubscription exposing (GroupMembershipUpdatedPayload)
import ViewHelpers exposing (setFocus, displayName, smartFormatDate, injectHtml, viewIf, viewUnless)


-- MODEL


type EditorState
    = NotEditing
    | Editing
    | Submitting


type alias FieldEditor =
    { state : EditorState
    , value : String
    , errors : List ValidationError
    }


type alias PostComposer =
    { body : String
    , isSubmitting : Bool
    }


type alias Model =
    { group : Group
    , state : GroupMembershipState
    , posts : Connection Component.Post.Model
    , featuredMemberships : List GroupMembership
    , now : Date
    , space : Space
    , user : SpaceUser
    , nameEditor : FieldEditor
    , postComposer : PostComposer
    }



-- LIFECYCLE


init : SpaceUser -> Space -> String -> Session -> Task Session.Error ( Session, Model )
init user space groupId session =
    Date.now
        |> Task.andThen (GroupInit.request space.id groupId session)
        |> Task.andThen (buildModel user space)


buildModel : SpaceUser -> Space -> ( Session, GroupInit.Response ) -> Task Session.Error ( Session, Model )
buildModel user space ( session, { group, state, posts, featuredMemberships, now } ) =
    let
        model =
            { group = group
            , state = state
            , posts = posts
            , featuredMemberships = featuredMemberships
            , now = now
            , space = space
            , user = user
            , nameEditor = (FieldEditor NotEditing "" [])
            , postComposer = (PostComposer "" False)
            }
    in
        Task.succeed ( session, model )


setup : Model -> Cmd Msg
setup { group, posts } =
    let
        pageCmd =
            Cmd.batch
                [ setFocus "post-composer" NoOp
                , Autosize.init "post-composer"
                , setupSockets group.id
                ]

        postsCmd =
            Connection.toList posts
                |> List.map (\post -> Cmd.map (PostComponentMsg post.id) (Component.Post.setup post))
                |> Cmd.batch
    in
        Cmd.batch [ pageCmd, postsCmd ]


teardown : Model -> Cmd Msg
teardown { group, posts } =
    let
        pageCmd =
            teardownSockets group.id

        postsCmd =
            Connection.toList posts
                |> List.map (\post -> Cmd.map (PostComponentMsg post.id) (Component.Post.teardown post))
                |> Cmd.batch
    in
        Cmd.batch [ pageCmd, postsCmd ]


setupSockets : String -> Cmd Msg
setupSockets groupId =
    GroupSubscription.subscribe groupId


teardownSockets : String -> Cmd Msg
teardownSockets groupId =
    GroupSubscription.unsubscribe groupId



-- UPDATE


type Msg
    = NoOp
    | Tick Time
    | NewPostBodyChanged String
    | NewPostSubmit
    | NewPostSubmitted (Result Session.Error ( Session, PostToGroup.Response ))
    | MembershipStateToggled GroupMembershipState
    | MembershipStateSubmitted (Result Session.Error ( Session, UpdateGroupMembership.Response ))
    | NameClicked
    | NameEditorChanged String
    | NameEditorDismissed
    | NameEditorSubmit
    | NameEditorSubmitted (Result Session.Error ( Session, UpdateGroup.Response ))
    | FeaturedMembershipsRefreshed (Result Session.Error ( Session, FeaturedMemberships.Response ))
    | PostComponentMsg String Component.Post.Msg


update : Msg -> Repo -> Session -> Model -> ( ( Model, Cmd Msg ), Session )
update msg repo session ({ postComposer, nameEditor } as model) =
    case msg of
        NoOp ->
            noCmd session model

        Tick time ->
            { model | now = Date.fromTime time }
                |> noCmd session

        NewPostBodyChanged value ->
            { model | postComposer = { postComposer | body = value } }
                |> noCmd session

        NewPostSubmit ->
            if newPostSubmittable postComposer then
                let
                    cmd =
                        PostToGroup.request model.space.id model.group.id postComposer.body session
                            |> Task.attempt NewPostSubmitted
                in
                    ( ( { model | postComposer = { postComposer | isSubmitting = True } }, cmd ), session )
            else
                noCmd session model

        NewPostSubmitted (Ok ( session, response )) ->
            ( ( { model | postComposer = { postComposer | body = "", isSubmitting = False } }
              , Autosize.update "post-composer"
              )
            , session
            )

        NewPostSubmitted (Err Session.Expired) ->
            redirectToLogin session model

        NewPostSubmitted (Err _) ->
            -- TODO: display error message
            { model | postComposer = { postComposer | isSubmitting = False } }
                |> noCmd session

        MembershipStateToggled state ->
            let
                cmd =
                    UpdateGroupMembership.request model.space.id model.group.id state session
                        |> Task.attempt MembershipStateSubmitted
            in
                -- Update the state on the model optimistically
                ( ( { model | state = state }, cmd ), session )

        MembershipStateSubmitted _ ->
            -- TODO: handle errors
            noCmd session model

        NameClicked ->
            let
                group =
                    Repo.getGroup repo model.group

                newEditor =
                    { nameEditor | state = Editing, value = group.name, errors = [] }

                cmd =
                    Cmd.batch
                        [ setFocus "name-editor-value" NoOp
                        , Ports.select "name-editor-value"
                        ]
            in
                ( ( { model | nameEditor = newEditor }, cmd ), session )

        NameEditorChanged val ->
            noCmd session { model | nameEditor = { nameEditor | value = val } }

        NameEditorDismissed ->
            noCmd session { model | nameEditor = { nameEditor | state = NotEditing } }

        NameEditorSubmit ->
            let
                cmd =
                    UpdateGroup.request model.space.id model.group.id nameEditor.value session
                        |> Task.attempt NameEditorSubmitted
            in
                ( ( { model | nameEditor = { nameEditor | state = Submitting } }, cmd ), session )

        NameEditorSubmitted (Ok ( session, UpdateGroup.Success group )) ->
            let
                newModel =
                    { model
                        | group = group
                        , nameEditor = { nameEditor | state = NotEditing }
                    }
            in
                noCmd session newModel

        NameEditorSubmitted (Ok ( session, UpdateGroup.Invalid errors )) ->
            ( ( { model | nameEditor = { nameEditor | state = Editing, errors = errors } }
              , Ports.select "name-editor-value"
              )
            , session
            )

        NameEditorSubmitted (Err Session.Expired) ->
            redirectToLogin session model

        NameEditorSubmitted (Err _) ->
            let
                errors =
                    [ ValidationError "name" "Hmm, something went wrong." ]
            in
                ( ( { model | nameEditor = { nameEditor | state = Editing, errors = errors } }, Cmd.none )
                , session
                )

        FeaturedMembershipsRefreshed (Ok ( session, memberships )) ->
            ( ( { model | featuredMemberships = memberships }, Cmd.none ), session )

        FeaturedMembershipsRefreshed (Err Session.Expired) ->
            redirectToLogin session model

        FeaturedMembershipsRefreshed (Err _) ->
            noCmd session model

        PostComponentMsg postId msg ->
            case Connection.get postId model.posts of
                Just post ->
                    let
                        ( ( newPost, cmd ), newSession ) =
                            Component.Post.update msg model.space.id session post
                    in
                        ( ( { model | posts = Connection.update newPost model.posts }
                          , Cmd.map (PostComponentMsg postId) cmd
                          )
                        , newSession
                        )

                Nothing ->
                    noCmd session model


noCmd : Session -> Model -> ( ( Model, Cmd Msg ), Session )
noCmd session model =
    ( ( model, Cmd.none ), session )


redirectToLogin : Session -> Model -> ( ( Model, Cmd Msg ), Session )
redirectToLogin session model =
    ( ( model, Route.toLogin ), session )



-- EVENT HANDLERS


handlePostCreated : Post -> Model -> ( Model, Cmd Msg )
handlePostCreated post ({ posts, group } as model) =
    let
        component =
            Component.Post.init Component.Post.Feed post
    in
        ( { model | posts = Connection.prepend component posts }
        , Cmd.map (PostComponentMsg post.id) (Component.Post.setup component)
        )


handleGroupMembershipUpdated : GroupMembershipUpdatedPayload -> Session -> Model -> ( Model, Cmd Msg )
handleGroupMembershipUpdated { state, membership } session model =
    let
        newState =
            if membership.user.id == model.user.id then
                state
            else
                model.state

        cmd =
            FeaturedMemberships.request model.space.id model.group.id session
                |> Task.attempt FeaturedMembershipsRefreshed
    in
        ( { model | state = newState }, cmd )


handleReplyCreated : Reply -> Model -> ( Model, Cmd Msg )
handleReplyCreated ({ postId } as reply) ({ posts } as model) =
    case Connection.get postId posts of
        Just component ->
            let
                ( newComponent, cmd ) =
                    Component.Post.handleReplyCreated reply component
            in
                ( { model | posts = Connection.update newComponent posts }
                , Cmd.map (PostComponentMsg postId) cmd
                )

        Nothing ->
            ( model, Cmd.none )


isMembershipListed : GroupMembership -> List GroupMembership -> Bool
isMembershipListed membership list =
    List.any (\m -> m.user.id == membership.user.id) list


removeMembership : GroupMembership -> List GroupMembership -> List GroupMembership
removeMembership membership list =
    List.filter (\m -> not (m.user.id == membership.user.id)) list



-- SUBSCRIPTION


subscriptions : Sub Msg
subscriptions =
    every second Tick



-- VIEW


view : Repo -> Model -> Html Msg
view repo model =
    let
        group =
            Repo.getGroup repo model.group
    in
        div [ class "mx-56" ]
            [ div [ class "mx-auto max-w-90 leading-normal" ]
                [ div [ class "group-header sticky pin-t border-b py-4 bg-white z-50" ]
                    [ div [ class "flex items-center" ]
                        [ nameView group model.nameEditor
                        , nameErrors model.nameEditor
                        , controlsView model.state
                        ]
                    ]
                , newPostView model.postComposer model.user group
                , postsView model.user model.now model.posts
                , sidebarView model.featuredMemberships
                ]
            ]


nameView : Group -> FieldEditor -> Html Msg
nameView group editor =
    case editor.state of
        NotEditing ->
            h2 [ class "flex-no-shrink" ]
                [ span
                    [ onClick NameClicked
                    , class "font-extrabold text-2xl cursor-pointer"
                    ]
                    [ text group.name ]
                ]

        Editing ->
            h2 [ class "flex-no-shrink" ]
                [ input
                    [ type_ "text"
                    , id "name-editor-value"
                    , classList
                        [ ( "-ml-2 px-2 bg-grey-light font-extrabold text-2xl text-dusty-blue-darkest rounded no-outline js-stretchy", True )
                        , ( "shake", not <| List.isEmpty editor.errors )
                        ]
                    , value editor.value
                    , onInput NameEditorChanged
                    , onKeydown preventDefault
                        [ ( [], enter, \event -> NameEditorSubmit )
                        , ( [], esc, \event -> NameEditorDismissed )
                        ]
                    , onBlur NameEditorDismissed
                    ]
                    []
                ]

        Submitting ->
            h2 [ class "flex-no-shrink" ]
                [ input
                    [ type_ "text"
                    , class "-ml-2 px-2 bg-grey-light font-extrabold text-2xl text-dusty-blue-darkest rounded no-outline"
                    , value editor.value
                    , disabled True
                    ]
                    []
                ]


nameErrors : FieldEditor -> Html Msg
nameErrors editor =
    case ( editor.state, List.head editor.errors ) of
        ( Editing, Just error ) ->
            span [ class "ml-2 flex-grow text-sm text-red font-bold" ] [ text error.message ]

        ( _, _ ) ->
            text ""


controlsView : GroupMembershipState -> Html Msg
controlsView state =
    div [ class "flex flex-grow justify-end" ]
        [ subscribeButtonView state
        ]


subscribeButtonView : GroupMembershipState -> Html Msg
subscribeButtonView state =
    case state of
        NotSubscribed ->
            button
                [ class "btn btn-grey-outline btn-xs"
                , onClick (MembershipStateToggled Subscribed)
                ]
                [ text "Join" ]

        Subscribed ->
            button
                [ class "btn btn-turquoise-outline btn-xs"
                , onClick (MembershipStateToggled NotSubscribed)
                ]
                [ text "Member" ]


newPostView : PostComposer -> SpaceUser -> Group -> Html Msg
newPostView ({ body, isSubmitting } as postComposer) user group =
    label [ class "composer mb-4" ]
        [ div [ class "flex" ]
            [ div [ class "flex-no-shrink mr-2" ] [ personAvatar Avatar.Medium user ]
            , div [ class "flex-grow" ]
                [ textarea
                    [ id "post-composer"
                    , class "p-2 w-full h-10 no-outline bg-transparent text-dusty-blue-darkest resize-none leading-normal"
                    , placeholder "Compose a new post..."
                    , onInput NewPostBodyChanged
                    , onKeydown preventDefault [ ( [ Meta ], enter, \event -> NewPostSubmit ) ]
                    , readonly isSubmitting
                    , value body
                    ]
                    []
                , div [ class "flex justify-end" ]
                    [ button
                        [ class "btn btn-blue btn-md"
                        , onClick NewPostSubmit
                        , disabled (not (newPostSubmittable postComposer))
                        ]
                        [ text "Post message" ]
                    ]
                ]
            ]
        ]


postsView : SpaceUser -> Date -> Connection Component.Post.Model -> Html Msg
postsView currentUser now connection =
    if Connection.isEmptyAndExpanded connection then
        div [ class "pt-8 pb-8 text-center text-lg" ]
            [ text "Nobody has posted in this group yet." ]
    else
        div [] <|
            Connection.map (postView currentUser now) connection


postView : SpaceUser -> Date -> Component.Post.Model -> Html Msg
postView currentUser now component =
    Component.Post.view currentUser now component
        |> Html.map (PostComponentMsg component.id)


sidebarView : List GroupMembership -> Html Msg
sidebarView featuredMemberships =
    div [ class "fixed pin-t pin-r w-56 mt-3 py-2 pl-6 border-l min-h-half" ]
        [ h3 [ class "mb-2 text-base font-extrabold" ] [ text "Members" ]
        , memberListView featuredMemberships
        ]


memberListView : List GroupMembership -> Html Msg
memberListView featuredMemberships =
    if List.isEmpty featuredMemberships then
        div [ class "text-sm" ] [ text "Nobody has joined yet." ]
    else
        div [] <| List.map memberItemView featuredMemberships


memberItemView : GroupMembership -> Html Msg
memberItemView { user } =
    div [ class "flex items-center pr-4 mb-px" ]
        [ div [ class "flex-no-shrink mr-2" ] [ personAvatar Avatar.Tiny user ]
        , div [ class "flex-grow text-sm truncate" ] [ text <| displayName user ]
        ]



-- UTILS


newPostSubmittable : PostComposer -> Bool
newPostSubmittable { body, isSubmitting } =
    not (body == "") && not isSubmitting
