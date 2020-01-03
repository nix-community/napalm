const path = require('path');

var HtmlWebpackPlugin = require('html-webpack-plugin');

module.exports = {
  entry: [
    './src/index.js'
  ],
  output: {
    path: path.resolve(__dirname, 'build'),
    publicPath: '/',
    filename: 'bundle.js'
  },
  module: {
    rules: [
      {
        use: {
          loader: 'babel-loader',
          options: {
            presets: ['react', 'es2015', 'stage-1']
          }
        },
        exclude: /node_modules/,
        test: /\.js$/
      },
      {
        test: /\.(jpe?g|png|gif|svg)$/,
        use: [
          {
            loader: 'url-loader',
            options: { limit: 1024 }
          },
          'image-webpack-loader'
        ]
      },
      {
        use: ['style-loader', 'css-loader'],
        test: /\.css$/
      },
      {
         test: /\.(scss)$/,
         use: [
           {
             loader: 'style-loader', // inject CSS to page
           },
           {
             loader: 'css-loader', // translates CSS into CommonJS modules
           },
           {
             loader: 'postcss-loader', // Run post css actions
             options: {
               plugins: function () { // post css plugins, can be exported to postcss.config.js
                 return [
                   require('precss'),
                   require('autoprefixer')
                 ];
               }
             }
           },
           {
             loader: 'sass-loader' // compiles Sass to CSS
           }
         ]
       },
    ]
  },
  resolve: {
    extensions: ['.js', '.jsx']
  },
  devServer: {
    historyApiFallback: true,
    contentBase: './build',
    host: '0.0.0.0',
    port: 8080,
    proxy: {
      '/graphql': {
        target: (process.env.API_URL || 'http://localhost:8090'),
        changeOrigin: true,
        ws: true
      }
    }
  },
  plugins: [new HtmlWebpackPlugin({
    title: 'something',
    template: path.resolve(__dirname, 'src/index.html'),
  })]
};
