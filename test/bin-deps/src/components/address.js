import React, { Component } from 'react'
import Container from 'react-bootstrap/Container'
import Row from 'react-bootstrap/Row'
import Col from 'react-bootstrap/Col'
import gql from 'graphql-tag'
import { Query } from 'react-apollo'
import Card from 'react-bootstrap/Card'
import { Link } from 'react-router-dom'

const GET_SEMANTIC_AND_TRACES = gql`
  query SemanticsFor($address: String!) {
    semanticsFor(address: $address) {
      transactionHash
      transactionIndex
      blockNumber
      semantics
    }
  }
`

const addressRe = "0x[0-9A-Fa-f]{40}"
const addressMatchRe = new RegExp(`(${addressRe})`)
const addressTestRe = new RegExp(`^${addressRe}$`)

// Get the semantic text and return JSX from it
function renderSemantic(semantic) {
  const ret = semantic.split(addressMatchRe).map((elem, idx) => {
    if (addressTestRe.test(elem)) {
      return (
        <span key={idx}>
          <Link to={`/address/${elem}`}>{elem}</Link>
        </span>
      )
    } else {
      return <span key={idx}>{elem}</span>
    }
  })
  return <div>{ret}</div>
}

class SemanticsFor extends Component {
  render() {
    const semantics = this.props.semantics
    return (
      <Card className="mt-5">
        <Card.Header>
          <span title="Block number">{semantics.blockNumber}</span>
          <span> / </span>
          <span title="Block index">{semantics.transactionIndex}</span>
          <span title="Transaction hash" className="float-right"><Link to={`/transaction_sequence/${semantics.transactionHash}`}>{semantics.transactionHash}</Link></span>
        </Card.Header>
        <Card.Body>
          <ul>
            {semantics.semantics.map(
              (sem, idx) => <li key={idx}>{renderSemantic(sem)}</li>
            )}
          </ul>
        </Card.Body>
      </Card>
    )
  }
}

export default class Index extends Component {
  render() {
    const address = this.props.match.params.address
    return (
        <Container>
          <Row>
            <Col>
              <Query
                query={GET_SEMANTIC_AND_TRACES}
                variables={ {address} }
              >
                {({ loading, error, data }) => {
                  if (loading) return <div>Loading...</div>
                  if (error) return <div>Error :(</div>

                  if (data.semanticsFor.length === 0) {
                    return <h3>No Transactions found for <b>{address}</b></h3>
                  }

                  return (
                    <div>
                      {
                        data.semanticsFor.map((sem) => <SemanticsFor semantics={sem} key={sem.blockNumber} />)
                      }
                    </div>
                  )
                }}
              </Query>
            </Col>
          </Row>
        </Container>
    )
  }

}
