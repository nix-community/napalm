import React, { Component } from 'react'
import Container from 'react-bootstrap/Container'
 
import SequenceDiagram from 'react-sequence-diagram'
import { Query } from 'react-apollo'
import gql from 'graphql-tag'

const GET_TRANSACTION_SEQUENCE = gql`
  query TransactionSequence($transactionHash: String!) {  
    transactionSequence(transactionHash: $transactionHash) {
      names {
        name
        address
      }
      diagram
    }
  }
`

const options = {
  theme: 'simple'
}
 
function onError(error) {
  console.log(error)
}


export default class Index extends Component {
    render() {
      const transactionHash = this.props.match.params.transactionHash
      return (
          <Container>
                <Query
                  query={GET_TRANSACTION_SEQUENCE}
                  variables={ {transactionHash} }
                >
                  {({ loading, error, data }) => {
                    if (loading) return <div>Loading...</div>
                    if (error) return <div>Error :(</div>                    
                    return (
                      <div>
                        <div>
                          {
                            <SequenceDiagram input={data.transactionSequence.diagram} options={options} onError={onError} />
                          }
                        </div>
                        <dl>
                          {
                            data.transactionSequence.names.map((n) => <div key={n.name}><strong>{n.name}</strong> - {n.address}</div>)
                          }
                        </dl>
                      </div>
                    )
                  }}
                </Query>
          </Container>
      )
    }
  
  }
  