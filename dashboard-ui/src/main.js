import "./app.css";
import { mount } from "svelte";
import App from "./App.svelte";
import { connect } from "./lib/state.svelte.js";

connect();
mount(App, { target: document.getElementById("app") });
