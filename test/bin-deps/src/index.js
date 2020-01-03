import React from 'react'
import ReactDOM from 'react-dom'
import ApolloClient from 'apollo-client'
import { ApolloProvider } from 'react-apollo'
import { InMemoryCache } from 'apollo-cache-inmemory'
import { split } from 'apollo-link'
import { createHttpLink, HttpLink } from 'apollo-link-http'
import { WebSocketLink } from 'apollo-link-ws'
import { getMainDefinition } from 'apollo-utilities'
import { ApolloLink } from 'apollo-link'
import { onError } from 'apollo-link-error'
import {BrowserRouter, Route} from 'react-router-dom'
import { IconContext } from 'react-icons'
import Root from './components/root'
import Address from './components/address'
import TransactionSequence from './components/transaction_sequence'
import 'bootstrap'
import './style/main.scss'
import NavBar from './components/nav_bar'

const wsProtocol = location.protocol === "https:" ? "wss" : "ws"

const wsLink = new WebSocketLink({
  uri: `${wsProtocol}://${location.host}/graphql/query`,
  options: {
    reconnect: true
  }
})

const httpLink = new HttpLink({
  uri: `${location.protocol}//${location.host}/graphql/query`,
})


const link = ApolloLink.from(
  [
    onError(({ graphQLErrors, networkError }) => {
      if (graphQLErrors)
        graphQLErrors.map(({ message, locations, path }) =>
          toast.error(
            `[GraphQL error]: Message: ${message}, Location: ${locations}, Path: ${path}`,
          ),
        );
      if (networkError) toast.error(`[Network error]: ${networkError}`);
    }),
    split(
      // split based on operation type
      ({ query }) => {
        const { kind, operation } = getMainDefinition(query);
        return kind === 'OperationDefinition' && operation === 'subscription';
      },
      wsLink,
      httpLink,
    )
])

const client = new ApolloClient({ link: link, cache: new InMemoryCache() })


ReactDOM.render(
  <ApolloProvider client={client}>
      <BrowserRouter>
        <NavBar />
        <div>
          <Route exact path="/" component={Root} />
          <Route exact path="/address/:address" component={Address} />
          <Route exact path="/transaction_sequence/:transactionHash" component={TransactionSequence} />
        </div>
      </BrowserRouter>
  </ApolloProvider>,
  document.getElementById('root')
)
