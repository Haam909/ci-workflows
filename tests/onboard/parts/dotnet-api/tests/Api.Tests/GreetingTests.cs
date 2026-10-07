using Api;

public class GreetingTests
{
    [Fact]
    public void Greets_by_name() => Assert.Equal("Hello, world!", Greeting.For("world"));
}
