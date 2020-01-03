import React, { Component } from 'react'
import Button from 'react-bootstrap/Button'
import Form from 'react-bootstrap/Form'
import Container from 'react-bootstrap/Container'
import Row from 'react-bootstrap/Row'
import Col from 'react-bootstrap/Col'
import Jumbotron from 'react-bootstrap/Jumbotron'

export default class Index extends Component {

  constructor(props) {
    super(props)
    this.state = {address: ""}
    this.handleChange = this.handleChange.bind(this)
    this.addressValid = this.addressValid.bind(this)
  }

  handleChange(event) {    
    this.setState({address: event.target.value})
  }

  addressValid() {
    return this.state.address.match(/^0x[0-9a-zA-Z]{40}$/)
  }

  render() {
    return (
      <Jumbotron>
        <Container>
          <Row>
            <Col>
              <Form onSubmit={() => {this.props.history.push(`/address/${this.state.address}`)}}>
                <Form.Group controlId="ethereumAddress">
                  <Form.Label>Ethereum Address</Form.Label>
                  <Form.Control size="lg" type="text" placeholder="0xaddress" value={this.state.value} onChange={this.handleChange} />
                  <Form.Text className="text-muted">
                    Enter an Ethereum address.
                  </Form.Text>
                </Form.Group>
                <Button variant="primary" type="submit" disabled={!this.addressValid()}>Show</Button>
              </Form>
            </Col>
          </Row>
        </Container>
      </Jumbotron>
    )
  }

}
