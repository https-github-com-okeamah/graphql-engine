{-# OPTIONS_GHC -fno-warn-orphans #-}

module Hasura.Backends.MSSQL.Instances.Execute
  ( MultiplexedQuery' (..),
    multiplexRootReselect,
  )
where

import Data.Aeson.Extended qualified as J
import Data.HashMap.Strict qualified as Map
import Data.HashSet qualified as Set
import Data.List.NonEmpty qualified as NE
import Data.Text.Extended qualified as T
import Database.ODBC.SQLServer qualified as ODBC
import Hasura.Backends.MSSQL.Connection
import Hasura.Backends.MSSQL.FromIr as TSQL
import Hasura.Backends.MSSQL.Plan
import Hasura.Backends.MSSQL.SQL.Value (txtEncodedColVal)
import Hasura.Backends.MSSQL.ToQuery
import Hasura.Backends.MSSQL.Types as TSQL
import Hasura.Base.Error
import Hasura.EncJSON
import Hasura.GraphQL.Execute.Backend
import Hasura.GraphQL.Execute.LiveQuery.Plan
import Hasura.GraphQL.Parser
import Hasura.Prelude
import Hasura.RQL.IR
import Hasura.RQL.Types
import Hasura.RQL.Types qualified as RQLTypes
import Hasura.RQL.Types.Column qualified as RQLColumn
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.Session
import Language.GraphQL.Draft.Syntax qualified as G

instance BackendExecute 'MSSQL where
  type PreparedQuery 'MSSQL = Text
  type MultiplexedQuery 'MSSQL = MultiplexedQuery'
  type ExecutionMonad 'MSSQL = ExceptT QErr IO

  mkDBQueryPlan = msDBQueryPlan
  mkDBMutationPlan = msDBMutationPlan
  mkDBSubscriptionPlan = msDBSubscriptionPlan
  mkDBQueryExplain = msDBQueryExplain
  mkLiveQueryExplain = msDBLiveQueryExplain

  -- NOTE: Currently unimplemented!.
  --
  -- This function is just a stub for future implementation; for now it just
  -- throws a 500 error.
  mkDBRemoteRelationshipPlan =
    msDBRemoteRelationshipPlan

-- Multiplexed query

newtype MultiplexedQuery' = MultiplexedQuery' Reselect

instance T.ToTxt MultiplexedQuery' where
  toTxt (MultiplexedQuery' reselect) = T.toTxt $ toQueryPretty $ fromReselect reselect

-- Query

msDBQueryPlan ::
  forall m.
  ( MonadError QErr m
  ) =>
  UserInfo ->
  SourceName ->
  SourceConfig 'MSSQL ->
  QueryDB 'MSSQL (Const Void) (UnpreparedValue 'MSSQL) ->
  m (DBStepInfo 'MSSQL)
msDBQueryPlan userInfo sourceName sourceConfig qrf = do
  -- TODO (naveen): Append Query Tags to the query
  let sessionVariables = _uiSession userInfo
  statement <- planQuery sessionVariables qrf
  let printer = fromSelect statement
      queryString = ODBC.renderQuery $ toQueryPretty printer
      pool = _mscConnectionPool sourceConfig
      odbcQuery = encJFromText <$> runJSONPathQuery pool (toQueryFlat printer)
  pure $ DBStepInfo @'MSSQL sourceName sourceConfig (Just $ queryString) odbcQuery

runShowplan ::
  ODBC.Query -> ODBC.Connection -> IO [Text]
runShowplan query conn = do
  ODBC.exec conn "SET SHOWPLAN_TEXT ON"
  texts <- ODBC.query conn query
  ODBC.exec conn "SET SHOWPLAN_TEXT OFF"
  -- we don't need to use 'finally' here - if an exception occurs,
  -- the connection is removed from the resource pool in 'withResource'.
  pure texts

msDBQueryExplain ::
  MonadError QErr m =>
  G.Name ->
  UserInfo ->
  SourceName ->
  SourceConfig 'MSSQL ->
  QueryDB 'MSSQL (Const Void) (UnpreparedValue 'MSSQL) ->
  m (AB.AnyBackend DBStepInfo)
msDBQueryExplain fieldName userInfo sourceName sourceConfig qrf = do
  let sessionVariables = _uiSession userInfo
  statement <- planQuery sessionVariables qrf
  let query = toQueryPretty (fromSelect statement)
      queryString = ODBC.renderQuery $ query
      pool = _mscConnectionPool sourceConfig
      odbcQuery =
        withMSSQLPool
          pool
          ( \conn -> do
              showplan <- runShowplan query conn
              pure
                ( encJFromJValue $
                    ExplainPlan
                      fieldName
                      (Just queryString)
                      (Just showplan)
                )
          )
  pure $
    AB.mkAnyBackend $
      DBStepInfo @'MSSQL sourceName sourceConfig Nothing odbcQuery

msDBLiveQueryExplain ::
  (MonadIO m, MonadError QErr m) =>
  LiveQueryPlan 'MSSQL (MultiplexedQuery 'MSSQL) ->
  m LiveQueryPlanExplanation
msDBLiveQueryExplain (LiveQueryPlan plan sourceConfig variables) = do
  let (MultiplexedQuery' reselect) = _plqpQuery plan
      query = toQueryPretty $ fromSelect $ multiplexRootReselect [(dummyCohortId, variables)] reselect
      pool = _mscConnectionPool sourceConfig
  explainInfo <- withMSSQLPool pool (runShowplan query)
  pure $ LiveQueryPlanExplanation (T.toTxt query) explainInfo variables

--------------------------------------------------------------------------------
-- Producing the correct SQL-level list comprehension to multiplex a query

-- Problem description:
--
-- Generate a query that repeats the same query N times but with
-- certain slots replaced:
--
-- [ Select x y | (x,y) <- [..] ]
--

multiplexRootReselect ::
  [(CohortId, CohortVariables)] ->
  TSQL.Reselect ->
  TSQL.Select
multiplexRootReselect variables rootReselect =
  Select
    { selectTop = NoTop,
      selectProjections =
        [ FieldNameProjection
            Aliased
              { aliasedThing =
                  TSQL.FieldName
                    { fieldNameEntity = rowAlias,
                      fieldName = resultIdAlias
                    },
                aliasedAlias = resultIdAlias
              },
          ExpressionProjection
            Aliased
              { aliasedThing =
                  ColumnExpression
                    ( TSQL.FieldName
                        { fieldNameEntity = resultAlias,
                          fieldName = TSQL.jsonFieldName
                        }
                    ),
                aliasedAlias = resultAlias
              }
        ],
      selectFrom =
        Just $
          FromOpenJson
            Aliased
              { aliasedThing =
                  OpenJson
                    { openJsonExpression =
                        ValueExpression (ODBC.TextValue $ lbsToTxt $ J.encode variables),
                      openJsonWith =
                        Just $
                          NE.fromList
                            [ UuidField resultIdAlias (Just $ IndexPath RootPath 0),
                              JsonField resultVarsAlias (Just $ IndexPath RootPath 1)
                            ]
                    },
                aliasedAlias = rowAlias
              },
      selectJoins =
        [ Join
            { joinSource = JoinReselect rootReselect,
              joinJoinAlias =
                JoinAlias
                  { joinAliasEntity = resultAlias,
                    joinAliasField = Just TSQL.jsonFieldName
                  }
            }
        ],
      selectWhere = Where mempty,
      selectFor =
        JsonFor ForJson {jsonCardinality = JsonArray, jsonRoot = NoRoot},
      selectOrderBy = Nothing,
      selectOffset = Nothing
    }

-- mutation

msDBMutationPlan ::
  forall m.
  ( MonadError QErr m
  ) =>
  UserInfo ->
  Bool ->
  SourceName ->
  SourceConfig 'MSSQL ->
  MutationDB 'MSSQL (Const Void) (UnpreparedValue 'MSSQL) ->
  m (DBStepInfo 'MSSQL)
msDBMutationPlan _userInfo _stringifyNum _sourceName _sourceConfig _mrf =
  throw400 NotSupported "mutations are not supported in MSSQL"

-- subscription

msDBSubscriptionPlan ::
  forall m.
  ( MonadError QErr m,
    MonadIO m
  ) =>
  UserInfo ->
  SourceName ->
  SourceConfig 'MSSQL ->
  InsOrdHashMap G.Name (QueryDB 'MSSQL (Const Void) (UnpreparedValue 'MSSQL)) ->
  m (LiveQueryPlan 'MSSQL (MultiplexedQuery 'MSSQL))
msDBSubscriptionPlan UserInfo {_uiSession, _uiRole} _sourceName sourceConfig rootFields = do
  (reselect, prepareState) <- planSubscription rootFields _uiSession
  cohortVariables <- prepareStateCohortVariables sourceConfig _uiSession prepareState
  let parameterizedPlan = ParameterizedLiveQueryPlan _uiRole $ MultiplexedQuery' reselect

  pure $
    LiveQueryPlan parameterizedPlan sourceConfig cohortVariables

prepareStateCohortVariables :: (MonadError QErr m, MonadIO m) => SourceConfig 'MSSQL -> SessionVariables -> PrepareState -> m CohortVariables
prepareStateCohortVariables sourceConfig session prepState = do
  (namedVars, posVars) <- validateVariables sourceConfig session prepState
  let PrepareState {sessionVariables} = prepState
  pure $
    mkCohortVariables
      sessionVariables
      session
      namedVars
      posVars

-- | Ensure that the set of variables (with value instantiations) that occur in
-- a (RQL) query produce a well-formed and executable (SQL) query when
-- considered in isolation.
--
-- This helps avoiding cascading failures in multiplexed queries.
--
-- c.f. https://github.com/hasura/graphql-engine-mono/issues/1210.
validateVariables ::
  (MonadError QErr m, MonadIO m) =>
  SourceConfig 'MSSQL ->
  SessionVariables ->
  PrepareState ->
  m (ValidatedQueryVariables, ValidatedSyntheticVariables)
validateVariables sourceConfig sessionVariableValues prepState = do
  let PrepareState {sessionVariables, namedArguments, positionalArguments} = prepState

      -- We generate a single 'canary' query in the form:
      --
      -- SELECT ... [session].[x-hasura-foo] as [x-hasura-foo], ... as a, ... as b, ...
      -- FROM OPENJSON('...')
      -- WITH ([x-hasura-foo] NVARCHAR(MAX)) as [session]
      --
      -- where 'a', 'b', etc. are aliases given to positional arguments.
      -- Named arguments and session variables are aliased to themselves.
      --
      -- The idea being that if the canary query succeeds we can be
      -- reasonably confident that adding these variables to a query being
      -- polled will not crash the poller.

      occSessionVars =
        filterSessionVariables
          (\k _ -> Set.member k sessionVariables)
          sessionVariableValues

      expSes, expNamed, expPos :: [Aliased Expression]
      expSes = sessionReference <$> getSessionVariables occSessionVars
      expNamed =
        map
          ( \(n, v) -> Aliased (ValueExpression (RQLColumn.cvValue v)) (G.unName n)
          )
          $ Map.toList $ namedArguments

      -- For positional args we need to be a bit careful not to capture names
      -- from expNamed and expSes (however unlikely)
      expPos =
        zipWith
          (\n v -> Aliased (ValueExpression (RQLColumn.cvValue v)) n)
          (freshVars (expNamed <> expSes))
          positionalArguments

      projAll :: [Projection]
      projAll = map ExpressionProjection (expSes <> expNamed <> expPos)

      canaryQuery =
        if null projAll
          then Nothing
          else
            Just $
              renderQuery
                emptySelect
                  { selectProjections = projAll,
                    selectFrom = sessionOpenJson occSessionVars
                  }

  onJust
    canaryQuery
    ( \q -> do
        _ :: [[ODBC.Value]] <- withMSSQLPool (_mscConnectionPool sourceConfig) (`ODBC.query` q)
        pure ()
    )

  pure
    ( ValidatedVariables $ txtEncodedColVal <$> namedArguments,
      ValidatedVariables $ txtEncodedColVal <$> positionalArguments
    )
  where
    renderQuery :: Select -> ODBC.Query
    renderQuery = toQueryFlat . fromSelect

    freshVars :: [Aliased a] -> [Text]
    freshVars boundNames = filter (not . (`elem` map aliasedAlias boundNames)) chars

    -- Infinite list of expression aliases.
    chars :: [Text]
    chars = [y T.<>> x | y <- [""] <|> chars, x <- ['a' .. 'z']]

    sessionOpenJson :: SessionVariables -> Maybe From
    sessionOpenJson occSessionVars =
      nonEmpty (getSessionVariables occSessionVars)
        <&> \fields ->
          FromOpenJson $
            Aliased
              ( OpenJson
                  (ValueExpression $ ODBC.TextValue $ lbsToTxt $ J.encode occSessionVars)
                  (pure (sessField <$> fields))
              )
              "session"

    sessField :: Text -> JsonFieldSpec
    sessField var = StringField var Nothing

    sessionReference :: Text -> Aliased Expression
    sessionReference var = Aliased (ColumnExpression (TSQL.FieldName var "session")) var

--------------------------------------------------------------------------------
-- Remote Relationships (e.g. DB-to-DB Joins, remote schema joins, etc.)
--------------------------------------------------------------------------------

-- | Construct an action (i.e. 'DBStepInfo') which can marshal some remote
-- relationship information into a form that SQL Server can query against.
--
-- XXX: Currently unimplemented; the Postgres implementation uses
-- @jsonb_to_recordset@ to query the remote relationship, however this
-- functionality doesn't exist in SQL Server.
--
-- NOTE: The following typeclass constraints will be necessary when implementing
-- this function for real:
--
-- @
--   MonadQueryTags m
--   Backend 'MSSQL
-- @
msDBRemoteRelationshipPlan ::
  forall m.
  ( MonadError QErr m
  ) =>
  UserInfo ->
  SourceName ->
  SourceConfig 'MSSQL ->
  -- | List of json objects, each of which becomes a row of the table.
  NonEmpty J.Object ->
  -- | The above objects have this schema
  --
  -- XXX: What is this for/what does this mean?
  HashMap RQLTypes.FieldName (RQLTypes.Column 'MSSQL, RQLTypes.ScalarType 'MSSQL) ->
  -- | This is a field name from the lhs that *has* to be selected in the
  -- response along with the relationship.
  RQLTypes.FieldName ->
  (RQLTypes.FieldName, SourceRelationshipSelection 'MSSQL (Const Void) UnpreparedValue) ->
  m (DBStepInfo 'MSSQL)
msDBRemoteRelationshipPlan _userInfo _sourceName _sourceConfig _lhs _lhsSchema _argumentId _relationship = do
  throw500 "mkDBRemoteRelationshipPlan: SQL Server (MSSQL) does not currently support generalized joins."
